## PICA200 TEV (texture-environment combiner) recognizer — the 3DS "fragment"
## story.
##
## The PICA200 has NO programmable fragment stage. Per-fragment color is produced
## by up to 6 fixed-function TEV stages configured on the CPU via citro3d's
## C3D_TexEnv API. This module does NOT compile a fragment shader — it recognizes
## a *tiny* set of fragment-proc shapes (the 2D common cases) and emits a
## host-agnostic `TevStage` descriptor. Anything outside that set hard-errors at
## Nim-compile time: "the 3DS has no programmable fragment stage".
##
## Recognized (the body must be a single `fragColor = <expr>`):
##   fragColor = TEX                  -> Replace   (texture only)
##   fragColor = TEX * COLOR          -> Modulate  (texture x vertex/primary color)
##   fragColor = TEX + COLOR          -> Add
## where TEX is a `texture(sampler, uv)` call or a `tex*`/`sampl*`-named param,
## and COLOR is a `vert*`/`prim*`/`col*`-named param (or a constant).
##
## The consumer maps the descriptor to citro3d calls; `gpuFunc`/`gpuSource` give
## the exact GPU_* constant names (verified against boxy's citro3d_backend:
## c3dTexEnvSrc(env, C3D_BOTH_MODE, GPU_TEXTURE0, GPU_PRIMARY_COLOR, GPU_TEXTURE0);
## c3dTexEnvFunc(env, C3D_BOTH_MODE, GPU_MODULATE)).

import std/[macros, strutils]

type
  TevError* = object of CatchableError

  TevSource* = enum
    tevTexture0
    tevTexture1
    tevPrimaryColor   ## per-vertex (interpolated) color
    tevConstant
    tevPrevious       ## output of the previous TEV stage

  TevFunc* = enum
    tevReplace
    tevModulate
    tevAdd

  TevStage* = object
    fn*: TevFunc
    src0*, src1*, src2*: TevSource

proc gpuFunc*(f: TevFunc): string =
  ## The citro3d GPU combiner constant for a TevFunc.
  case f
  of tevReplace: "GPU_REPLACE"
  of tevModulate: "GPU_MODULATE"
  of tevAdd: "GPU_ADD"

proc gpuSource*(s: TevSource): string =
  ## The citro3d GPU source constant for a TevSource.
  case s
  of tevTexture0: "GPU_TEXTURE0"
  of tevTexture1: "GPU_TEXTURE1"
  of tevPrimaryColor: "GPU_PRIMARY_COLOR"
  of tevConstant: "GPU_CONSTANT"
  of tevPrevious: "GPU_PREVIOUS"

proc tevFail(msg: string, n: NimNode) {.noreturn.} =
  error("[Shady/TEV] " & msg, n)

proc sourceOf(n: NimNode): TevSource =
  ## Map an operand to a TEV source. A `texture(...)` call is texture0; otherwise
  ## classify by the operand's name. Check "tex" before "col" so "texColor" maps
  ## to the texture, not the primary color.
  var node = n
  while node.kind in {nnkHiddenStdConv, nnkConv, nnkHiddenDeref, nnkHiddenAddr}:
    node = node[^1]
  if node.kind in {nnkCall, nnkCommand} and node.len > 0 and
     node[0].kind in {nnkSym, nnkIdent} and node[0].strVal == "texture":
    return tevTexture0
  # Only a leaf operand can name a TEV source; a nested expression cannot —
  # the TEV combiner takes fixed register sources, not computed values.
  if node.kind notin {nnkSym, nnkIdent, nnkDotExpr}:
    tevFail("operand '" & node.repr & "' is too complex for a fixed-function " &
            "TEV source — the 3DS has no programmable fragment stage", n)
  let nm = node.repr.toLowerAscii
  if "tex" in nm or "sampl" in nm: tevTexture0
  elif "vert" in nm or "prim" in nm or "col" in nm: tevPrimaryColor
  elif "const" in nm: tevConstant
  elif "prev" in nm: tevPrevious
  else:
    tevFail("cannot map '" & node.repr & "' to a PICA200 TEV source " &
            "(name it tex*/sampl* for a texture, vert*/prim*/col* for vertex color)", n)

proc unwrap(n: NimNode): NimNode =
  result = n
  while result.kind in {nnkStmtList, nnkStmtListExpr, nnkHiddenStdConv,
                        nnkConv, nnkHiddenDeref, nnkHiddenAddr}:
    result = (if result.kind in {nnkStmtList, nnkStmtListExpr}: result[^1] else: result[^1])

proc recognize(rhs: NimNode): TevStage =
  let e = unwrap(rhs)
  case e.kind
  of nnkInfix:
    let op = e[0].strVal
    let s0 = sourceOf(e[1])
    let s1 = sourceOf(e[2])
    case op
    of "*": TevStage(fn: tevModulate, src0: s0, src1: s1, src2: tevPrevious)
    of "+": TevStage(fn: tevAdd, src0: s0, src1: s1, src2: tevPrevious)
    else:
      tevFail("operator '" & op & "' has no PICA200 TEV equivalent — the 3DS has " &
              "no programmable fragment stage (only Replace/Modulate/Add)", e)
  of nnkCall, nnkCommand, nnkSym, nnkIdent, nnkDotExpr:
    TevStage(fn: tevReplace, src0: sourceOf(e), src1: tevPrevious, src2: tevPrevious)
  else:
    tevFail("this fragment operation has no PICA200 TEV equivalent — the 3DS has " &
            "no programmable fragment stage; only texture / texture*color " &
            "(modulate) / texture+color (add) are expressible", e)

proc tevStageLit(t: TevStage): NimNode =
  ## Build the `TevStage(...)` construction AST for the macro to return.
  nnkObjConstr.newTree(
    bindSym("TevStage"),
    nnkExprColonExpr.newTree(ident("fn"), ident($t.fn)),
    nnkExprColonExpr.newTree(ident("src0"), ident($t.src0)),
    nnkExprColonExpr.newTree(ident("src1"), ident($t.src1)),
    nnkExprColonExpr.newTree(ident("src2"), ident($t.src2)),
  )

proc toTevInner*(s: NimNode): NimNode =
  let impl = s.getImpl()
  if impl.kind notin {nnkProcDef, nnkFuncDef}:
    tevFail("toTev expects a proc", s)
  let body = impl.body
  if body.kind == nnkEmpty:
    tevFail("proc has no body", impl)

  # Find the single `fragColor`/`gl_FragColor`/`*Color`-output assignment.
  var rhs: NimNode = nil
  proc scan(n: NimNode) =
    case n.kind
    of nnkAsgn:
      var lhs = n[0]
      while lhs.kind in {nnkHiddenDeref, nnkHiddenAddr}: lhs = lhs[0]
      if lhs.kind in {nnkSym, nnkIdent}:
        rhs = n[1]
    of nnkStmtList, nnkStmtListExpr:
      for c in n: scan(c)
    of nnkCommentStmt, nnkEmpty, nnkDiscardStmt: discard
    else:
      tevFail("only a single 'fragColor = <expr>' assignment is supported in a " &
              "TEV fragment proc (no logic — the 3DS has no programmable fragment " &
              "stage)", n)
  scan(body)
  if rhs == nil:
    tevFail("TEV fragment proc must assign its color output once", impl)
  tevStageLit(recognize(rhs))

macro toTev*(s: typed): TevStage =
  ## Recognize a restricted 2D fragment proc and return its fixed-function
  ## PICA200 TEV stage descriptor. NOT a fragment compiler — the 3DS has no
  ## programmable fragment stage; unsupported shapes hard-error.
  toTevInner(s)
