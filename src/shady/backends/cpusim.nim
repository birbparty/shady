## CPU-simulation runtime for Shady shaders — the pixie-dependent half.
##
## These types and procs let a shader `proc` also execute on the CPU (Shady's
## "test with echo, then run on the GPU" workflow) and back image samplers with
## real pixel data. They depend on `pixie`, so they are split out of
## `shady/backends/shared` (the codegen engine, which needs no pixie).
##
## `import shady` re-exports this module by default. Pass `-d:shadyNoPixie` to
## omit it — used on targets like the Nintendo 3DS (`-d:ds3`) where you only
## want shader codegen (e.g. `toPica`) and must not compile pixie into the
## binary. The shader codegen never calls these procs; it recognizes
## `texture`/`imageStore`/`texelFetch`/etc. as builtins by name.

import std/math, vmath, pixie
import shady/backends/shared
from chroma import ColorRGBX

export pixie

type
  ImageBuffer* = object
    image*: Image

  UImageBuffer* = object
    image*: Image

  Sampler2d* = object
    image*: Image

  SamplerCube* = object
    faces*: array[6, Image]

  Sampler2dShadow* = object
    image*: Image

  USampler2d* = object
    image*: Image

  Sampler2dArray* = object
    images*: seq[Image]

proc vec4*(c: ColorRGBX): Vec4 =
  vec4(
    c.r.float32/255,
    c.g.float32/255,
    c.b.float32/255,
    c.a.float32/255
  )

proc texelFetch*(buffer: Uniform[Sampler2D], pos: IVec2, level: int): Vec4 =
  let c = buffer.image[pos.x.int, pos.y.int]
  return vec4(c.r.float32/255, c.g.float32/255, c.b.float32/255, c.a.float32/255)

proc texelFetch*(buffer: Uniform[USampler2D], pos: IVec2, level: int): UVec4 =
  ## CPU stub for usampler2D; not used at runtime. Returns zeros.
  uvec4(0u32, 0u32, 0u32, 0u32)

proc imageLoad*(
  buffer: var UniformWriteOnly[UImageBuffer], index: int32
): UVec4 =
  result.x = buffer.image.data[index.int].r
  result.g = buffer.image.data[index.int].g
  result.b = buffer.image.data[index.int].b
  result.a = buffer.image.data[index.int].a

proc imageStore*(buffer: var UniformWriteOnly[UImageBuffer], index: int32,
    color: UVec4) =
  buffer.image.data[index.int].r = clamp(color.x, 0, 255).uint8
  buffer.image.data[index.int].g = clamp(color.y, 0, 255).uint8
  buffer.image.data[index.int].b = clamp(color.z, 0, 255).uint8
  buffer.image.data[index.int].a = clamp(color.w, 0, 255).uint8

proc imageStore*(buffer: var UniformWriteOnly[ImageBuffer], index: int32,
    color: Vec4) =
  buffer.image.data[index.int].r = clamp(color.x*255, 0, 255).uint8
  buffer.image.data[index.int].g = clamp(color.y*255, 0, 255).uint8
  buffer.image.data[index.int].b = clamp(color.z*255, 0, 255).uint8
  buffer.image.data[index.int].a = clamp(color.w*255, 0, 255).uint8

proc imageStore*(buffer: var Uniform[Sampler2D], pos: IVec2,
    color: Vec4) =
  buffer.image[pos.x.int, pos.y.int] = rgbx(
    clamp(color.x*255, 0, 255).uint8,
    clamp(color.y*255, 0, 255).uint8,
    clamp(color.z*255, 0, 255).uint8,
    clamp(color.w*255, 0, 255).uint8,
  )

proc texture*(buffer: Uniform[Sampler2D], pos: Vec2): Vec4 =
  let pos = pos - vec2(0.5 / buffer.image.width.float32, 0.5 /
      buffer.image.height.float32)
  buffer.image.getRgbaSmooth(
    ((pos.x mod 1.0) * buffer.image.width.float32),
    ((pos.y mod 1.0) * buffer.image.height.float32)
  ).vec4()

proc texture*(buffer: Uniform[SamplerCube], pos: Vec3): Vec4 =
  ## CPU stub for samplerCube; not used at runtime. Returns opaque black.
  vec4(0, 0, 0, 1)

proc texture*(buffer: Uniform[Sampler2dShadow], pos: Vec3): float32 =
  ## CPU stub for sampler2DShadow; not used at runtime. Returns fully lit.
  1.0

proc textureLod*(buffer: Uniform[SamplerCube], pos: Vec3, lod: float32): Vec4 =
  ## CPU stub for samplerCube textureLod; not used at runtime.
  texture(buffer, pos)

proc textureSize*(buffer: Uniform[Sampler2D], level: int): Vec2 =
  vec2(buffer.image.width.float32, buffer.image.height.float32)

proc textureSize*(buffer: Uniform[SamplerCube], level: int): Vec2 =
  let image = buffer.faces[0]
  vec2(image.width.float32, image.height.float32)

proc textureSize*(buffer: Uniform[Sampler2dShadow], level: int): Vec2 =
  vec2(buffer.image.width.float32, buffer.image.height.float32)

proc textureGrad*(
  s: Uniform[Sampler2D],
  uv: Vec3,
  dUVdx: Vec2,
  dUVdy: Vec2
): Vec4 =
  texture(s, uv.xy)

proc textureGrad*(
  s: Uniform[Sampler2DArray],
  uvw: Vec3,
  dUVdx: Vec2,
  dUVdy: Vec2
): Vec4 =
  vec4(0, 0, 0, 0)
