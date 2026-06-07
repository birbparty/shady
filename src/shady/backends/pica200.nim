## PICA200 vertex-shader backend for Shady (Nintendo 3DS).
##
## Leaf module: walks a *typed* proc's NimNode AST and emits picasso (`.v.pica`)
## assembly text. It deliberately does NOT import `shared` or thread through
## `language()`/`toCode` — the PICA200 is a register machine, not a C-family
## shading language, so it is a parallel pipeline (see the plan in
## `.agents/plans/2026-06-07-shady-3ds-pica200-support/02-...`).
##
## M1 scope (this file): straight-line vertex transforms — `mov`, `mul`, `add`,
## `mad`, `dp3`/`dp4`, `min`/`max`, vec construction, swizzles, a uniform `Mat4`
## or `Vec4`, vertex-attribute inputs, and output semantics. Anything outside
## that subset raises `PicaError` at Nim-compile time (fail loud, never emit
## assembly picasso would reject). The real liveness/16-register allocator and
## operand-bank materialization land in M3; M1 uses a naive temp counter.

import std/[macros, strutils, tables, sets]

type
  PicaError* = object of CatchableError

  OutputSemantic = enum
    semPosition = "position"
    semTexcoord0 = "texcoord0"
    semTexcoord1 = "texcoord1"
    semColor = "color"

  OutBinding = object
    reg: string            ## e.g. "outpos"
    semantic: OutputSemantic

  UniformInfo = object
    base: int              ## first c-register index
    size: int              ## 1 (vec4) or 4 (mat4)

  Ctx = object
    instrs: seq[string]
    decls: seq[string]     ## .fvec / .constf / .alias / .out lines
    tempCount: int
    inputs: Table[string, string]      ## param name -> "v0"
    uniforms: Table[string, UniformInfo]
    outputs: Table[string, OutBinding] ## param/global name -> binding
    constPool: Table[string, string]   ## "0.0,1.0,0.0,0.0" -> const name
    cReg: int                          ## next free c-register
    hasPosition: bool                  ## a position output was declared
    cbankNames: HashSet[string]        ## base names that live in the c-bank
                                       ## (uniforms + consts) — forbidden in src2

proc fail(msg: string, n: NimNode) {.noreturn.} =
  error("[Shady/PICA200] " & msg, n)

proc newTemp(ctx: var Ctx): string =
  result = "r" & $ctx.tempCount
  inc ctx.tempCount

# --- constant pooling -------------------------------------------------------

proc constLane(ctx: var Ctx, x, y, z, w: float): string =
  ## Pool a 4-lane float constant; return an operand naming it (no swizzle).
  let key = $x & "," & $y & "," & $z & "," & $w
  if key notin ctx.constPool:
    let name = "shady_c" & $ctx.constPool.len
    ctx.constPool[key] = name
    ctx.cbankNames.incl name
    ctx.decls.add ".constf " & name & "(" & key & ")"
  ctx.constPool[key]

proc scalarConst(ctx: var Ctx, v: float): string =
  ## A scalar constant — returns the bare pooled-const name (no swizzle). All
  ## four lanes hold `v`, so it reads correctly whether used as a full-width
  ## broadcast (arithmetic) or a single dest lane in a vec constructor.
  ctx.constLane(v, v, v, v)

# --- operand-bank reachability (PICA: src2 may NOT be a c-bank register) -----

proc baseToken(operand: string): string =
  ## The leading register identifier of an operand, before any '.'/'[' / '-'.
  var s = operand
  if s.len > 0 and s[0] == '-': s = s[1 .. ^1]
  let cut = s.find({'.', '['})
  if cut < 0: s else: s[0 ..< cut]

proc isCbank(ctx: Ctx, operand: string): bool =
  baseToken(operand) in ctx.cbankNames

proc emitBinary(ctx: var Ctx, op, a, b: string, commutative: bool): string =
  ## Emit `op dst, src1, src2` honoring the rule that src2 cannot be c-bank.
  ## Returns the destination temp.
  var sa = a
  var sb = b
  if ctx.isCbank(sb):
    if commutative and not ctx.isCbank(sa):
      swap sa, sb                      # move the c-bank operand into src1
    else:
      let r = ctx.newTemp()            # materialize the c-bank operand
      ctx.instrs.add "mov " & r & ", " & sb
      sb = r
  let t = ctx.newTemp()
  ctx.instrs.add op & " " & t & ", " & sa & ", " & sb
  t

# --- type classification (syntactic, alias-aware) ---------------------------

proc isUniformType(typeNode: NimNode): bool =
  typeNode.kind == nnkBracketExpr and typeNode[0].repr == "Uniform"

proc isVarType(typeNode: NimNode): bool =
  typeNode.kind == nnkVarTy

proc uniformInner(typeNode: NimNode): string =
  typeNode[1].repr   # "Mat4" / "Vec4" / GMat4[float32] etc.

proc semanticForOutput(name: string): OutputSemantic =
  ## Choose a PICA output semantic from the param name. Order matters: check
  ## "col" before the texcoord tokens so "ouTColor" isn't misread as a texcoord
  ## (it contains the substring "tc"). Keep tokens specific for the same reason.
  let n = name.toLowerAscii
  if n == "gl_position" or "pos" in n: semPosition
  elif "col" in n: semColor
  elif "uv" in n or "texcoord" in n or "uv1" in n: semTexcoord0
  else: semTexcoord0

# --- gather pass (formal params only for M1) --------------------------------

proc gather(ctx: var Ctx, formalParams: NimNode) =
  var vReg = 0
  for identDefs in formalParams:
    if identDefs.kind != nnkIdentDefs: continue
    let typeNode = identDefs[^2]
    for i in 0 ..< identDefs.len - 2:
      let name = identDefs[i].strVal
      if isVarType(typeNode):
        # output
        let sem = semanticForOutput(name)
        let reg =
          case sem
          of semPosition: "outpos"
          of semTexcoord0: "outtc0"
          of semTexcoord1: "outtc1"
          of semColor: "outclr"
        for existing in ctx.outputs.values:
          if existing.reg == reg:
            fail("two outputs map to the same PICA register '" & reg & "' (" &
                 $sem & "); rename one so its semantic differs " &
                 "(position/texcoord0/color)", identDefs)
        ctx.outputs[name] = OutBinding(reg: reg, semantic: sem)
        ctx.decls.add ".out " & reg & " " & $sem
        if sem == semPosition: ctx.hasPosition = true
      elif isUniformType(typeNode):
        let inner = uniformInner(typeNode)
        if "Mat4" in inner:
          ctx.uniforms[name] = UniformInfo(base: ctx.cReg, size: 4)
          ctx.cbankNames.incl name
          ctx.decls.add ".fvec " & name & "[4]"
          ctx.cReg += 4
        elif "Vec4" in inner or "Vec3" in inner or "Vec2" in inner:
          ctx.uniforms[name] = UniformInfo(base: ctx.cReg, size: 1)
          ctx.cbankNames.incl name
          ctx.decls.add ".fvec " & name
          ctx.cReg += 1
        else:
          fail("unsupported uniform type for PICA200: " & inner, identDefs)
      else:
        # vertex attribute input
        let reg = "v" & $vReg
        ctx.inputs[name] = reg
        ctx.decls.add ".alias " & name & " " & reg
        inc vReg

# --- expression lowering ----------------------------------------------------
#
# lower() returns an operand string (register + optional swizzle) for the value
# of `n`, emitting instructions into ctx as needed. M1 supports a deliberately
# small grammar; everything else hard-errors.

proc swizzleOf(field: string): string =
  ## Map a vmath component/swizzle accessor to a PICA swizzle suffix.
  case field
  of "x", "y", "z", "w", "r", "g", "b", "a",
     "xy", "xyz", "xyzw", "rgb", "rgba": field.multiReplace(
       ("r", "x"), ("g", "y"), ("b", "z"), ("a", "w"))
  else: ""

proc lower(ctx: var Ctx, n: NimNode): string

proc lowerVecCtor(ctx: var Ctx, n: NimNode): string =
  ## vec2/vec3/vec4(...) -> build into a fresh temp, return it.
  let t = ctx.newTemp()
  let comps = ["x", "y", "z", "w"]
  var lane = 0
  for i in 1 ..< n.len:
    let arg = n[i]
    # A vector-typed arg fills multiple lanes via its swizzle width.
    let opnd = ctx.lower(arg)
    # Heuristic width: count swizzle chars if present, else scalar.
    let dotIdx = opnd.rfind('.')
    let width =
      if dotIdx >= 0 and dotIdx < opnd.high: opnd.len - dotIdx - 1
      else: 1
    if width <= 1:
      ctx.instrs.add "mov " & t & "." & comps[lane] & ", " & opnd
      inc lane
    else:
      let dst = comps[lane ..< lane + width].join("")
      ctx.instrs.add "mov " & t & "." & dst & ", " & opnd
      lane += width
  t

proc lower(ctx: var Ctx, n: NimNode): string =
  case n.kind
  of nnkSym, nnkIdent:
    let name = n.strVal
    if name in ctx.inputs: return ctx.inputs[name]
    if name in ctx.uniforms: return name   # mat/vec uniform base name
    fail("unknown identifier in PICA200 shader: " & name, n)
  of nnkFloatLit .. nnkFloat64Lit:
    return ctx.scalarConst(n.floatVal)
  of nnkIntLit .. nnkInt64Lit:
    return ctx.scalarConst(n.intVal.float)
  of nnkDotExpr:
    let base = ctx.lower(n[0])
    let sw = swizzleOf(n[1].strVal)
    if sw.len == 0: fail("unsupported swizzle/field: " & n[1].repr, n)
    return base & "." & sw
  of nnkBracketExpr:
    # vmath fast path: obj.arr[i] -> obj.<component>
    if n[0].kind == nnkDotExpr and n[0][1].repr == "arr":
      let base = ctx.lower(n[0][0])
      # The index may be wrapped in a hidden conversion (arr[HiddenStdConv(0)]).
      var idxNode = n[1]
      while idxNode.kind in {nnkHiddenStdConv, nnkConv, nnkChckRange}:
        idxNode = idxNode[^1]
      if idxNode.kind notin {nnkIntLit .. nnkInt64Lit}:
        fail("non-constant component index", n)
      let comp = case idxNode.intVal
        of 0: "x"
        of 1: "y"
        of 2: "z"
        of 3: "w"
        else: fail("component index out of range: " & $idxNode.intVal, n)
      return base & "." & comp
    fail("unsupported bracket expression", n)
  of nnkCall, nnkCommand:
    let fn = n[0].strVal
    if fn in ["vec2", "vec3", "vec4"]:
      return ctx.lowerVecCtor(n)
    if fn in ["min", "max"] and n.len == 3:
      return ctx.emitBinary(fn, ctx.lower(n[1]), ctx.lower(n[2]),
        commutative = true)
    if fn in ["dot"] and n.len == 3:
      # dp4 writes a scalar; result is its .x lane.
      let t = ctx.emitBinary("dp4", ctx.lower(n[1]), ctx.lower(n[2]),
        commutative = true)
      return t & ".x"
    fail("unsupported call in PICA200 shader: " & fn, n)
  of nnkInfix:
    let op = n[0].strVal
    case op
    of "+":
      return ctx.emitBinary("add", ctx.lower(n[1]), ctx.lower(n[2]),
        commutative = true)
    of "*":
      return ctx.emitBinary("mul", ctx.lower(n[1]), ctx.lower(n[2]),
        commutative = true)
    of "-":
      # a - b  ->  add a, -b. Negation is an src2 modifier, so b must first be
      # reachable in src2 (not c-bank): materialize it if needed via emitBinary's
      # rule, then negate. Simplest correct form: compute b into a temp when it
      # is c-bank, else negate in place.
      var b = ctx.lower(n[2])
      if ctx.isCbank(b):
        let r = ctx.newTemp()
        ctx.instrs.add "mov " & r & ", " & b
        b = r
      let t = ctx.newTemp()
      ctx.instrs.add "add " & t & ", " & ctx.lower(n[1]) & ", -" & b
      return t
    else:
      fail("unsupported operator '" & op & "' in PICA200 shader", n)
  of nnkHiddenStdConv, nnkConv, nnkHiddenDeref, nnkHiddenAddr:
    return ctx.lower(n[^1])
  of nnkStmtListExpr:
    return ctx.lower(n[^1])
  else:
    fail("unsupported expression node " & $n.kind & " in PICA200 shader", n)

# --- statement lowering -----------------------------------------------------

proc isUniformMat4(ctx: Ctx, n: NimNode): bool =
  (n.kind in {nnkSym, nnkIdent}) and n.strVal in ctx.uniforms and
    ctx.uniforms[n.strVal].size == 4

proc lowerAssign(ctx: var Ctx, lhs, rhs: NimNode) =
  # The LHS of a `var`-param write is wrapped in a hidden deref.
  var lnode = lhs
  while lnode.kind in {nnkHiddenDeref, nnkHiddenAddr}:
    lnode = lnode[0]
  if lnode.kind notin {nnkSym, nnkIdent}:
    fail("unsupported assignment target " & $lnode.kind, lhs)
  let lname = lnode.strVal
  if lname notin ctx.outputs:
    fail("assignment target is not a declared output: " & lname, lhs)
  let dst = ctx.outputs[lname].reg

  # Special case: out = mat4 * vec4  ->  four dp4 directly into the output.
  if rhs.kind == nnkInfix and rhs[0].strVal == "*" and ctx.isUniformMat4(rhs[1]):
    let mat = rhs[1].strVal
    let vec = ctx.lower(rhs[2])
    for i, comp in ["x", "y", "z", "w"]:
      ctx.instrs.add "dp4 " & dst & "." & comp & ", " & mat & "[" & $i & "], " & vec
    return

  # General case: compute rhs, mov into the output (all four lanes).
  let src = ctx.lower(rhs)
  ctx.instrs.add "mov " & dst & ", " & src

proc lowerStmt(ctx: var Ctx, stmt: NimNode) =
  case stmt.kind
  of nnkAsgn:
    ctx.lowerAssign(stmt[0], stmt[1])
  of nnkCommentStmt, nnkEmpty, nnkDiscardStmt:
    discard
  of nnkStmtList, nnkStmtListExpr:
    for s in stmt: ctx.lowerStmt(s)
  of nnkVarSection, nnkLetSection:
    fail("local variables are not yet supported in PICA200 (M1)", stmt)
  else:
    fail("unsupported statement " & $stmt.kind & " in PICA200 shader", stmt)

proc lowerBody(ctx: var Ctx, body: NimNode) =
  ## `body` is the proc body — a single statement (e.g. bare nnkAsgn) or a
  ## nnkStmtList. Handle both.
  ctx.lowerStmt(body)

# --- assembly ---------------------------------------------------------------

proc toPicaInner*(s: NimNode): string =
  ## Entry point: `s` is a typed proc symbol. Returns picasso .v.pica text.
  let impl = s.getImpl()
  if impl.kind notin {nnkProcDef, nnkFuncDef}:
    fail("toPica expects a proc", s)

  let formalParams = impl.params         # nnkFormalParams
  let body = impl.body                   # single stmt or nnkStmtList
  if formalParams.kind != nnkFormalParams: fail("proc has no parameters", impl)
  if body.kind == nnkEmpty: fail("proc has no body", impl)

  var ctx = Ctx()
  ctx.gather(formalParams)
  if not ctx.hasPosition:
    # A vertex shader must write a position output.
    fail("PICA200 vertex shader must declare a 'var Vec4' position output " &
         "(e.g. gl_Position)", impl)
  ctx.lowerBody(body)

  when defined(shadyPicaDebug):
    echo "--- PICA AST ---"
    echo impl.treeRepr

  # Emit: header comment, declarations, then the main proc.
  result.add "; Generated by Shady toPica (PICA200 vertex shader)\n"
  result.add "; from " & s.strVal & "\n\n"
  for d in ctx.decls:
    result.add d & "\n"
  result.add "\n.proc main\n"
  for ins in ctx.instrs:
    result.add "\t" & ins & "\n"
  result.add "\tend\n"
  result.add ".end\n"

