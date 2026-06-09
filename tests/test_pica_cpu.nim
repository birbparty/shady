## PICA200 CPU↔GPU math-parity (host-only).
##
## A Shady shader proc is also valid Nim, so we can run the *same* vertex proc on
## the CPU and assert it computes what the PICA200 should. This validates the
## proc's math (vec construction, the transform, color normalization), NOT the
## AST→assembly lowering — the lowering is checked by the picasso oracle and
## golden structure in test_pica.nim, and end-to-end by the on-device render.
##
## Matrix-upload convention (pin this for the device side): the citro3d host
## uploads Mat4 uniforms in PICA's {w,z,y,x} C3D_FVec layout via c3dFVUnifMtx4x4.
## The CPU here uses vmath's Mat4*Vec4 directly; the host code is responsible for
## matching row/column order when it uploads the same matrix, or a transpose
## mismatch will look like a shader bug.

import std/math
import shady, vmath

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

proc `~=`(a, b: float32): bool = abs(a - b) < 1e-4
proc `~=`(a, b: Vec4): bool = a.x ~= b.x and a.y ~= b.y and a.z ~= b.z and a.w ~= b.w
proc `~=`(a, b: Vec2): bool = a.x ~= b.x and a.y ~= b.y

block identityTransform:
  # With an identity projection, vec4(x, y, 0, 1) must come out unchanged — this
  # verifies the constructor forces z=0 and w=1 (not z=inPos.z, w=0).
  var pos: Vec4
  var uv: Vec2
  var col: Vec4
  render2dVert(pos, mat4(1.0),
    vec2(100, 50), vec2(0.25, 0.75), vec4(255, 128, 0, 255), uv, col)
  doAssert pos ~= vec4(100, 50, 0, 1), $pos
  doAssert uv ~= vec2(0.25, 0.75), $uv
  # Color normalization: u8 [0,255] -> [0,1], clamped at 1.
  doAssert col ~= vec4(1.0, 128.0/255.0, 0.0, 1.0), $col

block colorClamp:
  # Values above 255 (shouldn't happen for u8, but the min() must still clamp).
  var pos: Vec4
  var uv: Vec2
  var col: Vec4
  render2dVert(pos, mat4(1.0),
    vec2(0, 0), vec2(0, 0), vec4(300, 255, 0, 255), uv, col)
  doAssert col.x ~= 1.0 and col.y ~= 1.0, $col   # 300/255 clamped to 1.0

block scaledTransform:
  # A non-identity transform (scale + translate) exercises the matrix multiply.
  # gl_Position.w must remain 1 (w lane comes from the constructor's 1.0).
  var m = mat4(1.0)
  m[0, 0] = 0.005'f32        # x: 0.005 * x  (+ translate via column 3, row 0)
  m[3, 0] = -1.0'f32
  m[1, 1] = 0.01'f32         # y: 0.01 * y
  m[3, 1] = -1.0'f32
  var pos: Vec4
  var uv: Vec2
  var col: Vec4
  render2dVert(pos, m, vec2(200, 100), vec2(0, 0), vec4(0, 0, 0, 255), uv, col)
  let expected = m * vec4(200, 100, 0, 1)
  doAssert pos ~= expected, $pos & " vs " & $expected
  doAssert pos.w ~= 1.0, $pos          # w preserved through the transform
  doAssert pos.z ~= 0.0, $pos          # input z forced to 0

echo "PICA200 CPU parity tests passed"
