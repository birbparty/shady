import shady, strutils, vmath

block:
  proc fragmentConstant(fragColor: var Vec4) =
    fragColor = vec4(1.0, 0.25, 0.0, 1.0)

  let glsl3Web = toShader(fragmentConstant, glsl3WebGL, shaderFragment)
  doAssert "#version 300 es" in glsl3Web
  doAssert "precision highp float;" in glsl3Web
  doAssert "out vec4 fragColor;" in glsl3Web

  let glsl3DesktopSource = toShader(fragmentConstant, glsl3Desktop, shaderFragment)
  doAssert "#version 330" in glsl3DesktopSource
  doAssert "out vec4 fragColor;" in glsl3DesktopSource

  let glsl4 = toShader(fragmentConstant, glsl4Desktop, shaderFragment)
  doAssert "#version 410" in glsl4
  doAssert "out vec4 fragColor;" in glsl4

  let hlsl = toHLSL(fragmentConstant, shaderFragment)
  doAssert "float4 PSMain(" in hlsl
  doAssert "float4 pos : SV_POSITION;" in hlsl
  doAssert ": SV_TARGET" in hlsl
  doAssert "float4 fragColor = float4(0.0, 0.0, 0.0, 0.0);" in hlsl
  doAssert "return fragColor;" in hlsl

  let msl = toMSL(fragmentConstant, shaderFragment)
  doAssert "#include <metal_stdlib>" in msl
  doAssert "fragment float4 fragmentMain()" in msl
  doAssert "float4 fragColor = float4(0.0, 0.0, 0.0, 0.0);" in msl
  doAssert "return fragColor;" in msl

block:
  proc vertexPass(
    vPos: Vec3,
    vCol: Vec3,
    gl_Position: var Vec4,
    vertColor: var Vec3
  ) =
    gl_Position = vec4(vPos.x, vPos.y, vPos.z, 1.0)
    vertColor = vCol

  let hlsl = toHLSL(vertexPass, shaderVertex)
  doAssert "struct VSOutput" in hlsl
  doAssert "VSOutput VSMain(" in hlsl
  doAssert "float4 pos : SV_POSITION;" in hlsl
  doAssert "output.pos = gl_Position;" in hlsl

  let msl = toMSL(vertexPass, shaderVertex)
  doAssert "struct VertexOut" in msl
  doAssert "vertex VertexOut vertexMain(" in msl
  doAssert "float pointSize [[point_size]];" in msl
  doAssert "output.pointSize = 1.0;" in msl
  doAssert "float4 position [[position]];" in msl
  doAssert "output.position = gl_Position;" in msl

block:
  var atlas: Uniform[Sampler2d]

  proc sampledTexture(uv: Vec2, fragColor: var Vec4) =
    fragColor = texture(atlas, uv)

  let hlsl = toHLSL(sampledTexture, shaderFragment)
  doAssert "Texture2D<float4> atlas : register(t0);" in hlsl
  doAssert "SamplerState atlasSampler : register(s0);" in hlsl
  doAssert "atlas.Sample(atlasSampler, uv)" in hlsl

  let msl = toMSL(sampledTexture, shaderFragment)
  doAssert "texture2d<float> atlas [[texture(0)]]" in msl
  doAssert "atlas.sample(atlasSampler, uv)" in msl

block:
  var shadowMap: Uniform[Sampler2dShadow]

  proc sampledShadow(uvz: Vec3, fragColor: var Vec4) =
    let lit = texture(shadowMap, uvz)
    fragColor = vec4(lit, lit, lit, 1.0)

  let glsl = toShader(sampledShadow, glsl4Desktop, shaderFragment)
  doAssert "uniform sampler2DShadow shadowMap;" in glsl
  doAssert "texture(shadowMap, uvz)" in glsl

  let hlsl = toHLSL(sampledShadow, shaderFragment)
  doAssert "Texture2D<float> shadowMap : register(t0);" in hlsl
  doAssert "SamplerComparisonState shadowMapSampler : register(s0);" in hlsl
  doAssert "shadowMap.SampleCmpLevelZero(shadowMapSampler, uvz.xy, uvz.z)" in hlsl

  let msl = toMSL(sampledShadow, shaderFragment)
  doAssert "depth2d<float> shadowMap [[texture(0)]]" in msl
  doAssert "shadowMap.sample_compare(shadowMapSampler, uvz.xy, uvz.z)" in msl

block:
  var atlas: Uniform[Sampler2d]
  var viewportSize: Uniform[Vec2]

  func controlTint(texColor, vertexColor: Vec4): Vec4 =
    result = vec4(
      texColor.x * vertexColor.x,
      texColor.y * vertexColor.y,
      texColor.z * vertexColor.z,
      texColor.w * vertexColor.w
    )
    for i in 0 ..< 2:
      result.x += 0.05
    var steps = 0
    while steps < 2:
      result.z += 0.125
      inc steps
    if result.w < 0.5:
      result = vec4(0.0, 0.0, 0.0, 1.0)

  proc layoutVertex(
    position: Vec3,
    uv: Vec2,
    vertexColor: Vec4,
    gl_Position: var Vec4,
    fragmentUv: var Vec2,
    fragmentColor: var Vec4
  ) =
    gl_Position = vec4(position.x, position.y, position.z, 1.0)
    fragmentUv = uv
    fragmentColor = vertexColor

  proc layoutFragment(
    fragmentUv: Vec2,
    fragmentColor: Vec4,
    fragColor: var Vec4
  ) =
    let texColor = texture(atlas, fragmentUv)
    fragColor = controlTint(texColor, fragmentColor)

  let glsl3Vertex = toShader(layoutVertex, glsl3Desktop, shaderVertex)
  doAssert "in vec3 position;" in glsl3Vertex
  doAssert "in vec2 uv;" in glsl3Vertex
  doAssert "in vec4 vertexColor;" in glsl3Vertex
  doAssert "out vec2 fragmentUv;" in glsl3Vertex
  doAssert "out vec4 fragmentColor;" in glsl3Vertex

  let glsl3Fragment = toShader(layoutFragment, glsl3Desktop, shaderFragment)
  doAssert "uniform sampler2D atlas;" in glsl3Fragment
  doAssert "vec4 controlTint" in glsl3Fragment
  doAssert "for(int i = 0; i < 2; i++)" in glsl3Fragment
  doAssert "while(steps < 2)" in glsl3Fragment
  doAssert "if (" in glsl3Fragment
  doAssert "texture(atlas, fragmentUv)" in glsl3Fragment

  let glsl4Vertex = toShader(layoutVertex, glsl4Desktop, shaderVertex)
  doAssert "#version 410" in glsl4Vertex
  doAssert "in vec3 position;" in glsl4Vertex

  let vulkanVertex = toShader(layoutVertex, vulkanGlsl450, shaderVertex)
  doAssert "#version 450" in vulkanVertex
  doAssert "layout(location = 0) in vec3 position;" in vulkanVertex
  doAssert "layout(location = 1) in vec2 uv;" in vulkanVertex
  doAssert "layout(location = 2) in vec4 vertexColor;" in vulkanVertex
  doAssert "layout(location = 0) out vec2 fragmentUv;" in vulkanVertex
  doAssert "layout(location = 1) out vec4 fragmentColor;" in vulkanVertex
  doAssert "gl_Position.y = -gl_Position.y;" in vulkanVertex

  let hlslVertex = toHLSL(layoutVertex, shaderVertex)
  doAssert "float3 position : POSITION0" in hlslVertex
  doAssert "float2 uv : TEXCOORD0" in hlslVertex
  doAssert "float4 vertexColor : COLOR0" in hlslVertex
  doAssert "float2 fragmentUv : TEXCOORD0" in hlslVertex
  doAssert "float4 fragmentColor : COLOR0" in hlslVertex

  let hlslFragment = toHLSL(layoutFragment, shaderFragment)
  doAssert "Texture2D<float4> atlas : register(t0);" in hlslFragment
  doAssert "atlas.Sample(atlasSampler, fragmentUv)" in hlslFragment
  doAssert "float4 controlTint" in hlslFragment
  doAssert "for(int i = 0; i < 2; i++)" in hlslFragment
  doAssert "while(steps < 2)" in hlslFragment
  doAssert "if (" in hlslFragment

  let mslVertex = toMSL(layoutVertex, shaderVertex)
  doAssert "float3 position [[attribute(0)]]" in mslVertex
  doAssert "float2 uv [[attribute(1)]]" in mslVertex
  doAssert "float4 vertexColor [[attribute(2)]]" in mslVertex
  doAssert "float2 fragmentUv;" in mslVertex
  doAssert "float4 fragmentColor;" in mslVertex

  let mslFragment = toMSL(layoutFragment, shaderFragment)
  doAssert "texture2d<float> atlas [[texture(0)]]" in mslFragment
  doAssert "atlas.sample(atlasSampler, fragmentUv)" in mslFragment
  doAssert "float4 controlTint" in mslFragment
  doAssert "for(int i = 0; i < 2; i++)" in mslFragment
  doAssert "while(steps < 2)" in mslFragment
  doAssert "if (" in mslFragment

  proc uniformVertex(
    pos: Vec2,
    gl_Position: var Vec4
  ) =
    let clip = pos / viewportSize
    gl_Position = vec4(clip.x, clip.y, 0.0, 1.0)

  let hlslUniformVertex = toHLSL(uniformVertex, shaderVertex)
  doAssert "cbuffer ShadyUniforms0 : register(b0)" in hlslUniformVertex
  doAssert "float2 viewportSize;" in hlslUniformVertex
  doAssert "float2 pos : POSITION0" in hlslUniformVertex

  let vulkanUniformVertex = toShader(uniformVertex, vulkanGlsl450, shaderVertex)
  doAssert "layout(push_constant) uniform ShadyPushConstants" in vulkanUniformVertex
  doAssert "vec2 viewportSize;" in vulkanUniformVertex
  doAssert "#define viewportSize shadyPushConstants.viewportSize" in vulkanUniformVertex
  doAssert "layout(location = 0) in vec2 pos;" in vulkanUniformVertex

  let vulkanFragment = toShader(layoutFragment, vulkanGlsl450, shaderFragment)
  doAssert "layout(set = 0, binding = 0) uniform sampler2D atlas;" in vulkanFragment
  doAssert "layout(location = 0) in vec2 fragmentUv;" in vulkanFragment
  doAssert "layout(location = 1) in vec4 fragmentColor;" in vulkanFragment
  doAssert "layout(location = 0) out vec4 fragColor;" in vulkanFragment

block:
  # GLSL ES 1.00 (glslES1) target: attribute/varying, gl_FragColor, texture2D,
  # stage-aware mandatory precision, and fail-loud guards.
  var es1Sampler: Uniform[Sampler2d]

  proc es1Vertex(
    vertexPos: Vec2,
    vertexUv: Vec2,
    uv: var Vec2
  ) =
    uv = vertexUv
    gl_Position = vec4(vertexPos.x, vertexPos.y, 0.0, 1.0)

  proc es1Fragment(uv: Vec2, fragColor: var Vec4) =
    fragColor = texture(es1Sampler, uv)

  # Stage from body-scan: gl_Position is a module-global written in the body, and
  # the string overload "100" carries no stage argument.
  let es1Vert = toGLSL(es1Vertex, "100")
  doAssert "#version 100" in es1Vert
  doAssert "attribute vec2 vertexPos;" in es1Vert
  doAssert "varying vec2 uv;" in es1Vert
  doAssert "in vec2" notin es1Vert
  doAssert "out vec2" notin es1Vert
  doAssert "precision" notin es1Vert  # vertex defaults to highp; no precision line

  let es1Frag = toShader(es1Fragment, glslES1, shaderFragment)
  doAssert "#version 100" in es1Frag
  doAssert "precision mediump float;" in es1Frag
  doAssert "gl_FragColor = texture2D(es1Sampler, uv)" in es1Frag
  doAssert "varying vec2 uv;" in es1Frag
  doAssert "out vec4 fragColor;" notin es1Frag  # user output dropped
  doAssert "texture2D" in es1Frag and "texture(" notin es1Frag

  # Fail-loud: constructs ES1 cannot legally express must not compile under glslES1,
  # while remaining valid under ES3/desktop.
  proc usesRound(uv: Vec2, fragColor: var Vec4) =
    fragColor = vec4(round(uv.x))
  proc usesSwitch(k: int, fragColor: var Vec4) =
    case k
    of 0: fragColor = vec4(0.0)
    else: fragColor = vec4(1.0)
  proc usesTexSize(t: Uniform[Sampler2d], fragColor: var Vec4) =
    fragColor = vec4(textureSize(t, 0).x)
  proc intVarying(flag: int, fragColor: var Vec4) =
    fragColor = vec4(float(flag))
  proc multiOut(uv: Vec2, a: var Vec4, b: var Vec4) =
    a = vec4(0.0)
    b = vec4(1.0)

  doAssert not compiles(toShader(usesRound, glslES1, shaderFragment))
  doAssert not compiles(toShader(usesSwitch, glslES1, shaderFragment))
  doAssert not compiles(toShader(usesTexSize, glslES1, shaderFragment))
  doAssert not compiles(toShader(intVarying, glslES1, shaderFragment))
  doAssert not compiles(toShader(multiOut, glslES1, shaderFragment))
  # No false positives on other targets.
  doAssert compiles(toShader(usesRound, glslES3, shaderFragment))
  doAssert compiles(toShader(usesSwitch, glsl4Desktop, shaderFragment))

echo "Backend codegen tests passed"
