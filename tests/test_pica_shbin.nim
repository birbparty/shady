## toPicaShbin: assemble a PICA200 vertex shader with picasso at Nim-compile
## time and embed the .shbin bytes inline. Self-skips when picasso is not on
## PATH (e.g. CI without devkitPro), so it is safe to run anywhere.

import shady, vmath

proc basicVert(
  gl_Position: var Vec4,
  projection: Uniform[Mat4],
  vPos: Vec3
) =
  gl_Position = projection * vec4(vPos.x, vPos.y, vPos.z, 1.0)

const hasPicasso = staticExec("command -v picasso").len > 0

when hasPicasso:
  const shbin = toPicaShbin(basicVert)
  # A DVLB/.shbin always begins with the "DVLB" magic and is non-trivially sized.
  doAssert shbin.len > 0, "toPicaShbin produced empty bytes"
  doAssert shbin[0 .. 3] == "DVLB",
    "expected a DVLB .shbin header, got: " & shbin[0 .. min(3, shbin.high)]
  echo "toPicaShbin assembled ", shbin.len, " bytes (DVLB ok)"
else:
  echo "picasso not found — skipping toPicaShbin assemble test"

echo "PICA200 toPicaShbin test passed"
