## PICA200 vertex-shader backend tests (Nintendo 3DS).
##
## Host-only: validates that `toPica` emits well-formed picasso assembly for the
## supported vertex-shader subset, and — when `picasso` is on PATH — that the
## output actually assembles (the cheap, strong oracle from the 3DS plan).
## Register allocation may differ from a hand-written shader, so these are
## structural/behavioral checks, not byte-for-byte goldens.

import std/[os, osproc, strutils]
import shady, vmath

proc assembles(name, src: string): bool =
  ## Run picasso on `src` if available; true if it assembles (or picasso absent).
  let picasso = findExe("picasso")
  if picasso.len == 0:
    echo "  picasso not found — skipping assemble oracle for ", name
    return true
  let dir = getTempDir()
  let pin = dir / ("shady_test_" & name & ".v.pica")
  let pout = dir / ("shady_test_" & name & ".shbin")
  writeFile(pin, src)
  let (outp, code) = execCmdEx(picasso & " " & quoteShell(pin) &
    " -o " & quoteShell(pout))
  defer:
    removeFile(pin)
    removeFile(pout)
  if code != 0:
    echo "  picasso REJECTED ", name, ":\n", outp, "\n--- source ---\n", src
    return false
  result = fileExists(pout) and getFileSize(pout) > 0

# --- shape 1: 2D ortho transform — reproduces boxy's render2d.v.pica ---------

proc render2dVert(
  gl_Position: var Vec4,
  projection: Uniform[Mat4],
  inPos: Vec2,
  inUv: Vec2,
  inColor: Vec4,
  outUv: var Vec2,
  outColor: var Vec4
) =
  gl_Position = projection * vec4(inPos.x, inPos.y, 0.0, 1.0)
  outUv = inUv
  outColor = min(inColor * (1.0/255.0), vec4(1.0, 1.0, 1.0, 1.0))

const render2d = toPica(render2dVert)

block render2dStructure:
  # ABI the citro3d host depends on: uniform-by-name, attribute order, semantics.
  doAssert ".fvec projection[4]" in render2d, render2d
  doAssert ".alias inPos v0" in render2d, render2d
  doAssert ".alias inUv v1" in render2d, render2d
  doAssert ".alias inColor v2" in render2d, render2d
  doAssert ".out outpos position" in render2d, render2d
  doAssert ".out outtc0 texcoord0" in render2d, render2d
  doAssert ".out outclr color" in render2d, render2d
  # mat4*vec4 -> four dp4, uniform in src1 (operand-bank rule). The temp register
  # number is assigned by allocation, so match the bank-significant prefix only.
  doAssert "dp4 outpos.x, projection[0], r" in render2d, render2d
  doAssert "dp4 outpos.w, projection[3], r" in render2d, render2d
  # Color normalize: the const is forced into src1 of mul (src2 can't be c-bank).
  doAssert ", shady_c2, v2" in render2d, render2d
  doAssert "min " in render2d, render2d
  doAssert assembles("render2d", render2d)

# --- shape 2: 3D MVP transform, different attribute layout ------------------

proc mvp3dVert(
  gl_Position: var Vec4,
  mvp: Uniform[Mat4],
  inPos: Vec3,
  inNormal: Vec3,
  outNormal: var Vec3
) =
  gl_Position = mvp * vec4(inPos.x, inPos.y, inPos.z, 1.0)
  outNormal = inNormal

const mvp3d = toPica(mvp3dVert)

block mvp3dStructure:
  doAssert ".fvec mvp[4]" in mvp3d, mvp3d
  doAssert ".alias inPos v0" in mvp3d, mvp3d
  doAssert ".alias inNormal v1" in mvp3d, mvp3d
  doAssert ".out outpos position" in mvp3d, mvp3d
  doAssert "dp4 outpos.x, mvp[0], r" in mvp3d, mvp3d
  doAssert assembles("mvp3d", mvp3d)

# --- shape 3: mad fusion + read-port legalization ---------------------------

proc madVert(
  gl_Position: var Vec4,
  mvp: Uniform[Mat4],
  inPos: Vec3,
  inA: Vec4,
  inB: Vec4,
  inC: Vec4,
  outColor: var Vec4
) =
  gl_Position = mvp * vec4(inPos.x, inPos.y, inPos.z, 1.0)
  outColor = inA * inB + inC          # a*b + c -> mad

const madShader = toPica(madVert)

block madFusion:
  doAssert "mad " in madShader, madShader
  # inA*inB+inC reads three distinct input registers; PICA allows only one per
  # instruction, so two are materialized into temps first.
  doAssert madShader.count("mov r") >= 2, madShader
  doAssert assembles("mad", madShader)

# --- register allocation: reuse + the no-spill 16-register limit -------------

block registerReuse:
  # render2d reuses r0 (position vec, then color), so it must not climb past a
  # handful of physical registers despite allocating many virtual temps.
  var maxReg = 0
  for tok in render2d.split({' ', ',', '\n', '.', '['}):
    if tok.len >= 2 and tok[0] == 'r' and tok[1] in {'0'..'9'}:
      try: maxReg = max(maxReg, parseInt(tok[1 .. ^1])) except ValueError: discard
  doAssert maxReg < 8, "expected register reuse to keep render2d compact, got r" & $maxReg

block overBudget:
  # A shader that needs more than 16 simultaneously-live temps cannot run on the
  # PICA200 (no spilling) and must be rejected at compile time.
  proc tooManyTemps(
    gl_Position: var Vec4, mvp: Uniform[Mat4], inPos: Vec3,
    inColor: Vec4, outColor: var Vec4
  ) =
    gl_Position = mvp * vec4(inPos.x, inPos.y, inPos.z, 1.0)
    outColor = min(inColor * 20.0, min(inColor * 19.0, min(inColor * 18.0,
      min(inColor * 17.0, min(inColor * 16.0, min(inColor * 15.0,
      min(inColor * 14.0, min(inColor * 13.0, min(inColor * 12.0,
      min(inColor * 11.0, min(inColor * 10.0, min(inColor * 9.0,
      min(inColor * 8.0, min(inColor * 7.0, min(inColor * 6.0,
      min(inColor * 5.0, min(inColor * 4.0, min(inColor * 3.0,
      inColor * 2.0))))))))))))))))))
  doAssert not compiles(toPica(tooManyTemps)),
    "toPica should reject a shader exceeding 16 temp registers (no spilling)"

# --- fail-loud: a shader with no position output is rejected -----------------

block failLoud:
  # `fragColor` maps to the color semantic, so there is no position output —
  # toPica must reject it at compile time (PICA has no programmable fragment
  # stage; toPica is vertex-only).
  proc noPosition(fragColor: var Vec4, uv: Vec2) =
    fragColor = vec4(uv.x, uv.y, 0.0, 1.0)
  doAssert not compiles(toPica(noPosition)),
    "toPica should reject a shader with no position output"

echo "PICA200 backend tests passed"
