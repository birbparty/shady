## PICA200 TEV fragment-config recognizer tests (Nintendo 3DS).
##
## The 3DS has no programmable fragment stage; `toTev` recognizes a tiny set of
## fragment-proc shapes and returns a fixed-function TEV descriptor. These tests
## cover the recognized shapes, the GPU_* constant mapping (the citro3d ABI), and
## the hard-error path for anything the TEV can't express.

import shady, vmath

# --- recognized: texture x vertex color -> Modulate -------------------------

proc modulateFrag(fragColor: var Vec4, texColor: Vec4, vertColor: Vec4) =
  fragColor = texColor * vertColor

const modStage = toTev(modulateFrag)

block modulate:
  doAssert modStage.fn == tevModulate
  doAssert modStage.src0 == tevTexture0
  doAssert modStage.src1 == tevPrimaryColor
  # The exact citro3d constants boxy emits (c3dTexEnvFunc/Src).
  doAssert modStage.fn.gpuFunc == "GPU_MODULATE"
  doAssert modStage.src0.gpuSource == "GPU_TEXTURE0"
  doAssert modStage.src1.gpuSource == "GPU_PRIMARY_COLOR"

# --- applied path: descriptor -> citro3d GPU_* values ------------------------

block appliedPathContract:
  # A consumer maps the TevStage to citro3d's GPU_* enum values (libctru
  # 3ds/gpu/enums.h). For the modulate stage, toTev must yield exactly the values
  # boxy's hardware-verified citro3d backend uses:
  #   GPU_MODULATE=0x01, GPU_TEXTURE0=0x03, GPU_PRIMARY_COLOR=0x00.
  # (This was confirmed on a physical 3DS: driving boxy's modulate TEV from
  # toTev(boxyModulateFrag) renders identically to the hardcoded constants.)
  proc srcVal(s: TevSource): int =
    case s
    of tevPrimaryColor: 0x00
    of tevTexture0: 0x03
    of tevTexture1: 0x04
    of tevConstant: 0x0E
    of tevPrevious: 0x0F
  proc fnVal(f: TevFunc): int =
    case f
    of tevReplace: 0x00
    of tevModulate: 0x01
    of tevAdd: 0x02
  doAssert modStage.fn.fnVal == 0x01, "expected GPU_MODULATE"
  doAssert modStage.src0.srcVal == 0x03, "expected GPU_TEXTURE0"
  doAssert modStage.src1.srcVal == 0x00, "expected GPU_PRIMARY_COLOR"

# --- recognized: texture() call form ----------------------------------------

proc sampleFrag(
  fragColor: var Vec4, atlas: Uniform[Sampler2d], uv: Vec2, vertColor: Vec4
) =
  fragColor = texture(atlas, uv) * vertColor

block textureCall:
  const s = toTev(sampleFrag)
  doAssert s.fn == tevModulate
  doAssert s.src0 == tevTexture0      # texture(...) -> texture0
  doAssert s.src1 == tevPrimaryColor

# --- recognized: replace + add ----------------------------------------------

proc replaceFrag(fragColor: var Vec4, texColor: Vec4) =
  fragColor = texColor

proc addFrag(fragColor: var Vec4, texColor: Vec4, vertColor: Vec4) =
  fragColor = texColor + vertColor

block replaceAndAdd:
  const r = toTev(replaceFrag)
  doAssert r.fn == tevReplace and r.src0 == tevTexture0
  const a = toTev(addFrag)
  doAssert a.fn == tevAdd and a.src0 == tevTexture0 and a.src1 == tevPrimaryColor

# --- fail-loud: anything the TEV can't express ------------------------------

block rejectComputed:
  # A per-pixel computation has no fixed-function TEV equivalent.
  proc computedFrag(fragColor: var Vec4, uv: Vec2) =
    fragColor = vec4(smoothstep(0.0, 1.0, uv.x), 0.0, 0.0, 1.0)
  doAssert not compiles(toTev(computedFrag)),
    "toTev must reject a computed (programmable) fragment shader"

block rejectNestedOperand:
  # texture * color * scalar is not a single TEV stage.
  proc tripleFrag(fragColor: var Vec4, texColor: Vec4, vertColor: Vec4) =
    fragColor = texColor * vertColor * vertColor
  doAssert not compiles(toTev(tripleFrag)),
    "toTev must reject an operand that is itself a computed expression"

block rejectUnknownSource:
  # An operand that isn't a recognizable texture/color source.
  proc mysteryFrag(fragColor: var Vec4, foo: Vec4, bar: Vec4) =
    fragColor = foo * bar
  doAssert not compiles(toTev(mysteryFrag)),
    "toTev must reject operands it cannot map to a TEV source"

echo "PICA200 TEV recognizer tests passed"
