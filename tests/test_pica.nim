## PICA200 vertex-shader backend tests (Nintendo 3DS).
##
## Host-only: validates that `toPica` emits well-formed picasso assembly for the
## supported vertex-shader subset, and — when `picasso` is on PATH — that the
## output actually assembles (the cheap, strong oracle from the 3DS plan).

import std/[os, osproc, strutils]
import shady, vmath

# --- a basic MVP-style vertex transform ------------------------------------

proc basicVert(
  gl_Position: var Vec4,
  projection: Uniform[Mat4],
  vPos: Vec3
) =
  gl_Position = projection * vec4(vPos.x, vPos.y, vPos.z, 1.0)

const basicPica = toPica(basicVert)

block structure:
  # Declarations the citro3d host ABI depends on (uniform-by-name, output
  # semantics, attribute aliasing).
  doAssert ".fvec projection[4]" in basicPica, basicPica
  doAssert ".out outpos position" in basicPica, basicPica
  doAssert ".alias vPos v0" in basicPica, basicPica
  # Matrix * vec4 lowers to four dp4 with the uniform in src1 (operand-bank rule).
  doAssert "dp4 outpos.x, projection[0], r0" in basicPica, basicPica
  doAssert "dp4 outpos.w, projection[3], r0" in basicPica, basicPica
  # Proc framing.
  doAssert ".proc main" in basicPica
  doAssert basicPica.strip().endsWith(".end")

# --- picasso oracle (only where the toolchain is installed) -----------------

block picassoOracle:
  let picasso = findExe("picasso")
  if picasso.len == 0:
    echo "picasso not found — skipping assemble oracle (host-only structure ok)"
  else:
    let dir = getTempDir()
    let src = dir / "shady_test_basicVert.v.pica"
    let obj = dir / "shady_test_basicVert.shbin"
    writeFile(src, basicPica)
    let (outp, code) = execCmdEx(picasso & " " & quoteShell(src) &
      " -o " & quoteShell(obj))
    doAssert code == 0, "picasso rejected generated .v.pica:\n" & outp &
      "\n--- source ---\n" & basicPica
    doAssert fileExists(obj) and getFileSize(obj) > 0
    removeFile(src)
    removeFile(obj)
    echo "picasso assembled the generated shader (", getAppFilename().lastPathPart, ")"

echo "PICA200 backend tests passed"
