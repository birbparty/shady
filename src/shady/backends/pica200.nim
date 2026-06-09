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
    locals: Table[string, string]      ## local var/let name -> temp register
    loopConsts: Table[string, int]     ## unrolled for-loop var -> current value
    # Geometry-shader state (toGeoPica):
    primParam: string                  ## the Primitive[N,T] param name
    primFields: seq[string]            ## per-vertex field names (declaration order)
    geoEmitIndex: int                  ## next setemit index (0..2 within a primitive)
    geoLastSetemit: int                ## ctx.instrs index of the last `setemit`

proc fail(msg: string, n: NimNode) {.noreturn.} =
  error("[Shady/PICA200] " & msg, n)

proc newTemp(ctx: var Ctx): string =
  ## A *virtual* temp ("vt0", "vt1", …). The register-allocation pass
  ## (allocateRegisters) maps these to physical r0–r15, reusing registers once a
  ## virtual temp is dead. The "vt" prefix never collides with a real PICA
  ## register/output name (v0, outtc0, …).
  result = "vt" & $ctx.tempCount
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

proc isInput(operand: string): bool =
  ## True for a vertex-attribute register operand (v0..v15), not a temp (vtN).
  let b = baseToken(operand)
  b.len >= 2 and b[0] == 'v' and b[1] != 't' and
    b[1 .. ^1].allCharsInSet({'0'..'9'})

proc materialize(ctx: var Ctx, operand: string): string =
  ## mov `operand` into a fresh temp; return the temp.
  let r = ctx.newTemp()
  ctx.instrs.add "mov " & r & ", " & operand
  r

proc capReadPorts(ctx: var Ctx, ops: var seq[string]) =
  ## Enforce the PICA read-port limit: at most one distinct input (v) register
  ## and at most one c-bank (uniform/const) register per instruction. The same
  ## register reused in two slots is fine; a *different* one must be moved to a
  ## temp first. (Verified against picasso.)
  var keptInput = ""
  var keptC = ""
  for i in 0 ..< ops.len:
    let bt = baseToken(ops[i])
    if isInput(ops[i]):
      if keptInput == "" or keptInput == bt: keptInput = bt
      else: ops[i] = ctx.materialize(ops[i])
    elif ctx.isCbank(ops[i]):
      if keptC == "" or keptC == bt: keptC = bt
      else: ops[i] = ctx.materialize(ops[i])

proc emitBinary(ctx: var Ctx, op, a, b: string, commutative: bool): string =
  ## Emit `op dst, src1, src2` honoring the PICA operand rules: ≤1 input and ≤1
  ## c-bank read per instruction, and src2 may not be a c-bank register.
  var ops = @[a, b]
  ctx.capReadPorts(ops)              # legalize read ports first
  var sa = ops[0]
  var sb = ops[1]
  if ctx.isCbank(sb):                # src2 cannot be c-bank
    if commutative and not ctx.isCbank(sa):
      swap sa, sb
    else:
      sb = ctx.materialize(sb)
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

proc vecWidth(n: NimNode): int =
  ## Component count of a vector-typed node (2/3/4), or 0 if not determinable.
  let t =
    try: n.getTypeInst().repr
    except CatchableError: ""
  if "Vec4" in t or "GVec4" in t: 4
  elif "Vec3" in t or "GVec3" in t: 3
  elif "Vec2" in t or "GVec2" in t: 2
  else: 0

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
    if name in ctx.loopConsts: return ctx.scalarConst(ctx.loopConsts[name].float)
    if name in ctx.locals: return ctx.locals[name]
    if name in ctx.inputs: return ctx.inputs[name]
    if name in ctx.uniforms: return name   # mat/vec uniform base name
    fail("unknown identifier in PICA200 shader: " & name, n)
  of nnkFloatLit .. nnkFloat64Lit:
    return ctx.scalarConst(n.floatVal)
  of nnkIntLit .. nnkInt64Lit:
    return ctx.scalarConst(n.intVal.float)
  of nnkDotExpr:
    # Geometry input access: prim[<const>].<field> -> input register vN.
    # (Must resolve before the swizzle path, which would reject the field name.)
    if ctx.primParam.len > 0 and n[0].kind == nnkBracketExpr and
       n[0][0].kind in {nnkSym, nnkIdent} and n[0][0].strVal == ctx.primParam:
      var idxNode = n[0][1]
      while idxNode.kind in {nnkHiddenStdConv, nnkConv, nnkChckRange}:
        idxNode = idxNode[^1]
      if idxNode.kind notin {nnkIntLit .. nnkInt64Lit}:
        fail("geometry input index must be a constant: " & n[0][1].repr, n)
      let fieldIdx = ctx.primFields.find(n[1].strVal)
      if fieldIdx < 0:
        fail("'" & n[1].strVal & "' is not a vertex field of the primitive", n)
      let reg = idxNode.intVal.int * ctx.primFields.len + fieldIdx
      return "v" & $reg
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
      # Pick dp3/dp4 by operand width — dp4 on a Vec3 would add the padded w
      # lane and silently corrupt the result.
      let w = max(vecWidth(n[1]), vecWidth(n[2]))
      let dp =
        case w
        of 4: "dp4"
        of 3: "dp3"
        else: fail("dot() on PICA200 requires Vec3 or Vec4 operands (got " &
                   "width " & $w & ")", n)
      # dp3/dp4 write a scalar; result is its .x lane.
      let t = ctx.emitBinary(dp, ctx.lower(n[1]), ctx.lower(n[2]),
        commutative = true)
      return t & ".x"
    fail("unsupported call in PICA200 shader: " & fn, n)
  of nnkInfix:
    let op = n[0].strVal
    case op
    of "+":
      # Fuse  a*b + c  ->  mad t, a, b, c  (one instruction). PICA `mad`'s first
      # multiplicand (s1) may NOT be c-bank, but s2/s3 may — the opposite of
      # `mul` (verified with picasso). Pick the operand shape that satisfies it.
      let lMul = n[1].kind == nnkInfix and n[1][0].strVal == "*"
      let rMul = n[2].kind == nnkInfix and n[2][0].strVal == "*"
      if lMul or rMul:
        let mulN = if lMul: n[1] else: n[2]
        let addN = if lMul: n[2] else: n[1]
        var ops = @[ctx.lower(mulN[1]), ctx.lower(mulN[2]), ctx.lower(addN)]
        ctx.capReadPorts(ops)        # ≤1 input, ≤1 c-bank across the 3 sources
        var a = ops[0]               # s1 (first multiplicand)
        var b = ops[1]               # s2
        let c = ops[2]               # s3
        if ctx.isCbank(a):           # mad's s1 may NOT be c-bank
          if not ctx.isCbank(b):
            swap a, b                # mul is commutative
          else:
            a = ctx.materialize(a)
        let t = ctx.newTemp()
        ctx.instrs.add "mad " & t & ", " & a & ", " & b & ", " & c
        return t
      return ctx.emitBinary("add", ctx.lower(n[1]), ctx.lower(n[2]),
        commutative = true)
    of "*":
      return ctx.emitBinary("mul", ctx.lower(n[1]), ctx.lower(n[2]),
        commutative = true)
    of "-":
      # a - b  ->  add a, -b. Negation is an src2 modifier, so b sits in src2 —
      # which may not be c-bank; and the pair must obey the read-port limit.
      var ops = @[ctx.lower(n[1]), ctx.lower(n[2])]
      ctx.capReadPorts(ops)
      var b = ops[1]
      if ctx.isCbank(b):
        b = ctx.materialize(b)
      let t = ctx.newTemp()
      ctx.instrs.add "add " & t & ", " & ops[0] & ", -" & b
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

proc assignToReg(ctx: var Ctx, dst: string, rhs: NimNode) =
  ## Assign an expression to a specific output register. Shared by output-param
  ## assignment and geometry `emitVertex`. Handles the mat4*vec4 -> 4×dp4 case.
  if rhs.kind == nnkInfix and rhs[0].strVal == "*" and ctx.isUniformMat4(rhs[1]):
    let mat = rhs[1].strVal
    let vec = ctx.lower(rhs[2])
    for i, comp in ["x", "y", "z", "w"]:
      ctx.instrs.add "dp4 " & dst & "." & comp & ", " & mat & "[" & $i & "], " & vec
    return
  let src = ctx.lower(rhs)
  ctx.instrs.add "mov " & dst & ", " & src

proc lowerAssign(ctx: var Ctx, lhs, rhs: NimNode) =
  # The LHS of a `var`-param write is wrapped in a hidden deref.
  var lnode = lhs
  while lnode.kind in {nnkHiddenDeref, nnkHiddenAddr}:
    lnode = lnode[0]
  if lnode.kind notin {nnkSym, nnkIdent}:
    fail("unsupported assignment target " & $lnode.kind, lhs)
  let lname = lnode.strVal

  # Reassigning a mutable local: mov the value into the local's stable temp.
  if lname in ctx.locals:
    let src = ctx.lower(rhs)
    ctx.instrs.add "mov " & ctx.locals[lname] & ", " & src
    return

  if lname notin ctx.outputs:
    fail("assignment target is not a declared output or local: " & lname, lhs)
  ctx.assignToReg(ctx.outputs[lname].reg, rhs)

proc lowerStmt(ctx: var Ctx, stmt: NimNode)   # forward (mutual recursion)

# --- control flow: if/else -> cmp + ifc/.else/.end --------------------------

proc picaCmpOp(nimOp: string, n: NimNode): string =
  case nimOp
  of "<": "lt"
  of ">": "gt"
  of "<=": "le"
  of ">=": "ge"
  of "==": "eq"
  of "!=": "ne"
  else:
    fail("unsupported comparison '" & nimOp & "' in a PICA200 if-condition " &
         "(use < > <= >= == !=)", n)

proc invertCmpOp(op: string): string =
  ## Comparison with operands swapped: a<b == b>a, etc. (eq/ne are symmetric).
  case op
  of "lt": "gt"
  of "gt": "lt"
  of "le": "ge"
  of "ge": "le"
  else: op

proc emitCmp(ctx: var Ctx, cond: NimNode): string =
  ## Emit a `cmp` for a comparison; return the condition operand ("cmp.x").
  # The condition may be wrapped (a `>`/`>=` desugars to a flipped `<`/`<=`
  # inside a StmtListExpr).
  var c = cond
  while c.kind in {nnkStmtListExpr, nnkStmtList, nnkHiddenStdConv, nnkConv, nnkPar}:
    c = c[^1]
  if c.kind != nnkInfix:
    fail("a PICA200 'if' condition must be a comparison (a < b, a == b, ...)", cond)
  var op = picaCmpOp(c[0].strVal, c)
  var ops = @[ctx.lower(c[1]), ctx.lower(c[2])]
  ctx.capReadPorts(ops)               # <=1 input + <=1 c-bank per instruction
  var a = ops[0]
  var b = ops[1]
  if ctx.isCbank(b):                  # cmp src2 may not be c-bank; cmp isn't
    swap a, b                         # commutative, so swap operands AND invert
    op = invertCmpOp(op)
    if ctx.isCbank(b): b = ctx.materialize(b)
  # opx and opy both set; we read cmp.x.
  ctx.instrs.add "cmp " & a & ", " & op & ", " & op & ", " & b
  "cmp.x"

proc lowerIfBranch(ctx: var Ctx, n: NimNode, idx: int) =
  ## Emit branch `idx` of an nnkIfStmt (if / elif* / else) as nested
  ## cmp + ifc/.else/.end. (Top-level proc — a nested closure can't capture
  ## the `var Ctx`.)
  let br = n[idx]
  case br.kind
  of nnkElifBranch:
    let cond = ctx.emitCmp(br[0])
    ctx.instrs.add "ifc " & cond
    ctx.lowerStmt(br[1])
    if idx + 1 < n.len:
      ctx.instrs.add ".else"
      ctx.lowerIfBranch(n, idx + 1)
    ctx.instrs.add ".end"
  of nnkElse:
    ctx.lowerStmt(br[0])
  else:
    fail("unsupported if branch " & $br.kind, br)

proc lowerIf(ctx: var Ctx, n: NimNode) =
  ## n is nnkIfStmt: if / elif* / else. Lowers to nested cmp + ifc/.else/.end.
  ctx.lowerIfBranch(n, 0)

# --- locals and (unrolled) for loops ----------------------------------------

proc lowerLocalSection(ctx: var Ctx, sec: NimNode) =
  ## `let`/`var x = expr` — back each local with a stable temp (so a `var` can be
  ## reassigned, e.g. accumulated in a loop).
  for idef in sec:
    if idef.kind != nnkIdentDefs: continue
    let valNode = idef[^1]
    if valNode.kind == nnkEmpty:
      fail("a PICA200 local must be initialized (var x = ...)", idef)
    let val = ctx.lower(valNode)
    for i in 0 ..< idef.len - 2:
      let t = ctx.newTemp()
      ctx.instrs.add "mov " & t & ", " & val
      ctx.locals[idef[i].strVal] = t

proc constInt(n: NimNode): int =
  var x = n
  while x.kind in {nnkHiddenStdConv, nnkConv, nnkChckRange, nnkPar, nnkStmtListExpr}:
    x = x[^1]
  if x.kind in {nnkIntLit .. nnkInt64Lit}: x.intVal.int
  else: fail("a PICA200 for-loop bound must be a compile-time integer", n)

proc lowerFor(ctx: var Ctx, n: NimNode) =
  ## `for i in a ..< b` / `a .. b` with constant bounds — unrolled (the body runs
  ## once per index, with `i` available as a constant). The PICA200 also has a
  ## hardware `for`/loop register, but that needs an `.ivec` uniform set by the
  ## host; unrolling is self-contained and needs no host support.
  let loopVar = n[0]
  if loopVar.kind notin {nnkSym, nnkIdent}:
    fail("a PICA200 for-loop variable must be a simple name", n)
  let r = n[1]
  if r.kind notin {nnkInfix, nnkCall, nnkCommand} or r.len != 3 or
     r[0].repr notin ["..", "..<"]:
    fail("a PICA200 for-loop needs a constant integer range (for i in a ..< b)", n)
  let lo = constInt(r[1])
  let last = (if r[0].repr == "..": constInt(r[2]) else: constInt(r[2]) - 1)
  if last - lo + 1 > 256:
    fail("PICA200 for-loop unrolls to more than 256 iterations — too large " &
         "(the instruction budget is ~512)", n)
  let name = loopVar.strVal
  for k in lo .. last:
    ctx.loopConsts[name] = k
    ctx.lowerStmt(n[2])
  ctx.loopConsts.del(name)

# --- geometry emission: emitVertex / endPrimitive ---------------------------

proc lowerEmitVertex(ctx: var Ctx, call: NimNode) =
  ## emitVertex(position, color) -> setemit N; write outpos/outclr; emit.
  if call.len != 3:
    fail("emitVertex expects (position, color)", call)
  if ctx.geoEmitIndex > 2:
    fail("a PICA200 output primitive can emit at most 3 vertices " &
         "(setemit 0..2); call endPrimitive() to start a new one", call)
  ctx.instrs.add "setemit " & $ctx.geoEmitIndex
  ctx.geoLastSetemit = ctx.instrs.high
  ctx.assignToReg("outpos", call[1])
  ctx.assignToReg("outclr", call[2])
  ctx.instrs.add "emit"
  inc ctx.geoEmitIndex

proc lowerEndPrimitive(ctx: var Ctx, n: NimNode) =
  ## Flag the most recent setemit with `, prim` and reset the emit index.
  if ctx.geoLastSetemit < 0:
    fail("endPrimitive() with no preceding emitVertex()", n)
  ctx.instrs[ctx.geoLastSetemit] = ctx.instrs[ctx.geoLastSetemit] & ", prim"
  ctx.geoEmitIndex = 0
  ctx.geoLastSetemit = -1

proc lowerStmt(ctx: var Ctx, stmt: NimNode) =
  case stmt.kind
  of nnkAsgn:
    ctx.lowerAssign(stmt[0], stmt[1])
  of nnkIfStmt:
    ctx.lowerIf(stmt)
  of nnkForStmt:
    ctx.lowerFor(stmt)
  of nnkCall, nnkCommand:
    # Geometry emission verbs (only valid in a toGeoPica proc).
    case stmt[0].strVal
    of "emitVertex": ctx.lowerEmitVertex(stmt)
    of "endPrimitive": ctx.lowerEndPrimitive(stmt)
    else:
      fail("unsupported call '" & stmt[0].strVal & "' at statement level", stmt)
  of nnkVarSection, nnkLetSection:
    ctx.lowerLocalSection(stmt)
  of nnkCommentStmt, nnkEmpty, nnkDiscardStmt:
    discard
  of nnkStmtList, nnkStmtListExpr:
    for s in stmt: ctx.lowerStmt(s)
  else:
    fail("unsupported statement " & $stmt.kind & " in PICA200 shader", stmt)

proc lowerBody(ctx: var Ctx, body: NimNode) =
  ## `body` is the proc body — a single statement (e.g. bare nnkAsgn) or a
  ## nnkStmtList. Handle both.
  ctx.lowerStmt(body)

# --- register allocation: virtual temps (vtN) -> physical r0..r15 -----------
#
# Straight-line code, so liveness is one linear pass: each virtual temp is live
# from its first definition to its last use, and a physical register is reused
# once its temp dies. The PICA200 has 16 temp registers and NO spilling — if
# more than 16 are ever simultaneously live the shader cannot run, so we reject
# it at Nim-compile time rather than emit something the hardware can't execute.

const PicaTempRegs = 16

proc tempBase(operand: string): string =
  ## The "vtN" base of an operand, or "" if it is not a virtual temp.
  var s = operand
  if s.len > 0 and s[0] == '-': s = s[1 .. ^1]
  let cut = s.find({'.', '['})
  let b = if cut < 0: s else: s[0 ..< cut]
  if b.len > 2 and b[0] == 'v' and b[1] == 't' and
     b[2 .. ^1].allCharsInSet({'0'..'9'}): b
  else: ""

proc splitInstr(line: string): tuple[op: string, operands: seq[string]] =
  let sp = line.find(' ')
  if sp < 0: return (line, @[])
  result.op = line[0 ..< sp]
  for part in line[sp+1 .. ^1].split(", "):
    result.operands.add part

proc rewriteOperand(operand: string, pregOf: Table[string, int]): string =
  var sign = ""
  var s = operand
  if s.len > 0 and s[0] == '-': (sign = "-"; s = s[1 .. ^1])
  let cut = s.find({'.', '['})
  let base = if cut < 0: s else: s[0 ..< cut]
  let rest = if cut < 0: "" else: s[cut .. ^1]
  if base in pregOf: sign & "r" & $pregOf[base] & rest
  else: operand

proc allocateRegisters(ctx: var Ctx, errNode: NimNode) =
  var parsed: seq[tuple[op: string, operands: seq[string]]]
  var lastUse = initTable[string, int]()
  for i, line in ctx.instrs:
    let pi = splitInstr(line)
    parsed.add pi
    for o in pi.operands:
      let b = tempBase(o)
      if b.len > 0: lastUse[b] = i

  var pregOf = initTable[string, int]()         # vt -> physical (permanent)
  var occupant: array[PicaTempRegs, string]     # current vt per reg ("" = free)
  for i, pi in parsed:
    # Expire registers whose occupant's last use is strictly before this instr.
    for r in 0 ..< PicaTempRegs:
      if occupant[r].len > 0 and lastUse[occupant[r]] < i:
        occupant[r] = ""
    # Allocate the destination temp if newly defined. Control-flow ops read (or
    # don't touch) their first operand — they never define a temp there.
    let writesDest = pi.op notin ["cmp", "ifc", "for", "nop", "end"] and
                     not pi.op.startsWith(".")
    if writesDest and pi.operands.len > 0:
      let d = tempBase(pi.operands[0])
      if d.len > 0 and d notin pregOf:
        var chosen = -1
        for r in 0 ..< PicaTempRegs:
          if occupant[r].len == 0: chosen = r; break
        if chosen < 0:
          fail("vertex shader needs more than " & $PicaTempRegs &
               " temporary registers — the PICA200 has no register spilling; " &
               "simplify or split the shader", errNode)
        occupant[chosen] = d
        pregOf[d] = chosen

  for i in 0 ..< ctx.instrs.len:
    var lineOut = parsed[i].op
    if parsed[i].operands.len > 0:
      var outOps: seq[string]
      for o in parsed[i].operands:
        outOps.add rewriteOperand(o, pregOf)
      lineOut.add " " & outOps.join(", ")
    ctx.instrs[i] = lineOut

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
  ctx.allocateRegisters(impl)

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

# ===========================================================================
# Geometry shader backend (toGeoPica) — Nintendo 3DS PICA200 .g.pica
# ===========================================================================

proc geoGather(ctx: var Ctx, formalParams: NimNode) =
  for identDefs in formalParams:
    if identDefs.kind != nnkIdentDefs: continue
    let typeNode = identDefs[^2]
    for i in 0 ..< identDefs.len - 2:
      let name = identDefs[i].strVal
      if typeNode.kind == nnkBracketExpr and typeNode[0].repr == "Primitive":
        # Primitive[N, VertexT]: introspect VertexT's fields (declaration order)
        # -> per-vertex input registers. Field k of vertex j is v(j*nFields + k).
        ctx.primParam = name
        let td = typeNode[2].getImpl     # nnkTypeDef -> [name, generics, ObjectTy]
        if td.kind != nnkTypeDef or td[2].kind != nnkObjectTy:
          fail("Primitive vertex type must be an object", identDefs)
        for field in td[2][2]:           # ObjectTy -> recList
          if field.kind == nnkIdentDefs:
            for j in 0 ..< field.len - 2:
              ctx.primFields.add field[j].strVal
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
          fail("unsupported uniform type for PICA200 geometry: " & inner, identDefs)

proc toGeoPicaInner*(s: NimNode): string =
  ## Entry point: `s` is a typed geometry-shader proc. Returns picasso .g.pica.
  let impl = s.getImpl()
  if impl.kind notin {nnkProcDef, nnkFuncDef}:
    fail("toGeoPica expects a proc", s)
  let formalParams = impl.params
  let body = impl.body
  if formalParams.kind != nnkFormalParams: fail("proc has no parameters", impl)
  if body.kind == nnkEmpty: fail("geometry proc has no body", impl)

  var ctx = Ctx(geoLastSetemit: -1)
  ctx.geoGather(formalParams)
  if ctx.primParam.len == 0:
    fail("a PICA200 geometry proc must take a Primitive[N, T] input", impl)
  # v1 outputs (emitVertex writes these).
  ctx.decls.add ".out outpos position"
  ctx.decls.add ".out outclr color"
  ctx.lowerBody(body)
  ctx.allocateRegisters(impl)

  when defined(shadyPicaDebug):
    echo "--- GEO AST ---"
    echo impl.treeRepr

  result.add "; Generated by Shady toGeoPica (PICA200 geometry shader)\n"
  result.add "; from " & s.strVal & "\n\n"
  result.add ".gsh point c0\n"
  for d in ctx.decls:
    result.add d & "\n"
  result.add "\n.entry gmain\n.proc gmain\n"
  for ins in ctx.instrs:
    result.add "\t" & ins & "\n"
  result.add "\tend\n"
  result.add ".end\n"

