# Nim to GPU shader language compiler and supporting utilities.

Shady can compile a subset of Nim into `OpenGL Shader Language` used by the GPU. This allows you to test your shader code with `echo` statements on the CPU and then run the exact same code on the GPU.

`nimble install shady`

![Github Actions](https://github.com/treeform/shady/workflows/Github%20Actions/badge.svg)

[API reference](https://treeform.github.io/shady)

Shady has two main goals:

* Write vertex and fragment/pixel shaders for games and 3d applications.
* Write compute shaders for offline processing and number crunching.

Currently supported shader types:

* Fragment/pixel shaders, including shader-toy style fullscreen examples.
* Vertex shaders paired with fragment shaders for the traditional graphics pipeline.
* Compute shaders for GPU data processing.

Current shader targets:

* Desktop GLSL 4.10 via `glsl4Desktop` / `glslDesktop` for OpenGL 4.1+.
* Desktop GLSL 3.30 via `glsl3Desktop` for older desktop OpenGL tests.
* GLSL ES 3.0 via `glsl3WebGL` / `glslES3` for OpenGL ES 3.0 / WebGL 2.0.
* HLSL via `hlslDX12` for DirectX 12.
* Metal Shading Language via `metalMSL`.
* PICA200 vertex assembly via `pica200Vsh` for the Nintendo 3DS (experimental —
  vertex shaders only; see "Nintendo 3DS / PICA200" below).

Use `toShader(shaderProc, target, stage)` for the general backend switch, or
`toGLSL`, `toHLSL`, `toMSL`, and `toPica` for language-specific helpers.

Runtime backend tests are separate so platform graphics dependencies stay
optional:

```sh
nimble test
nim c -r -d:shadyRunOpenGL tests/test_opengl_glsl3.nim
nim c -r -d:shadyRunOpenGL tests/test_opengl_glsl4.nim
nim c -r --path:C:\p\dx12\src -d:shadyRunDx12 tests/test_directx.nim
nim c -r --path:/path/to/metal4/src -d:shadyRunMetal tests/test_metal.nim
```

Shady uses:
* `pixie` library for image operations.
* `vmath` library for vector and matrix operations.
* `chroma` library for color conversions and operations.
* `bumpy` library for collisions and intersections.

# Nintendo 3DS / PICA200 (experimental)

Shady can compile a **vertex** shader proc to [PICA200](https://www.3dbrew.org/wiki/GPU)
picasso assembly (`.v.pica`) for the Nintendo 3DS via `toPica`:

```nim
import shady, vmath

proc basicVert(
  gl_Position: var Vec4,
  projection: Uniform[Mat4],
  vPos: Vec3
) =
  gl_Position = projection * vec4(vPos.x, vPos.y, vPos.z, 1.0)

const picaSource = toPica(basicVert)
# Assemble with devkitPro's picasso, then load the .shbin via libctru/citro3d:
#   picasso basicVert.v.pica -o basicVert.shbin
```

Output:

```
.fvec projection[4]
.out outpos position
.alias vPos v0

.proc main
	mov r0.x, v0.x
	mov r0.y, v0.y
	mov r0.z, v0.z
	mov r0.w, shady_c0.x
	dp4 outpos.x, projection[0], r0
	dp4 outpos.y, projection[1], r0
	dp4 outpos.z, projection[2], r0
	dp4 outpos.w, projection[3], r0
	end
.end
```

**Important hardware constraints** (these are PICA200 facts, not Shady choices):

* **Vertex shaders only.** The PICA200 has **no programmable fragment stage** —
  per-pixel color comes from the fixed-function TEV combiners, configured on the
  CPU via citro3d. `toPica` rejects fragment shaders at compile time.
* **Param conventions.** Plain vector/float params become vertex attributes
  (`v0`, `v1`, …, in declaration order); a `Uniform[Mat4]`/`Uniform[Vec4]` param
  becomes a `.fvec` uniform (resolved by name on the host); a `var` output maps
  to a PICA output semantic (`position`/`texcoord0`/`color`) chosen by name.
* **Straight-line code only (current scope).** Control flow, geometry shaders,
  and shaders needing more than the 16 temp registers are rejected with a clear
  compile error (the PICA200 has no register spilling).
* Integer vertex attributes (e.g. `GPU_UNSIGNED_BYTE` colors) arrive
  **un-normalized**; divide by 255 in the shader if you need `[0,1]`.

Building Shady-consuming code for the 3DS (cross-compiled with devkitARM) should
pass **`-d:shadyNoPixie`** so the CPU-simulation runtime (which needs `pixie`) is
not compiled into the ARM binary — the shader codegen itself needs no pixie.

`tests/test_pica.nim` exercises `toPica` and, when `picasso` is on `PATH`, checks
that the generated assembly actually assembles.

# Using Shady shader toy playground:

![circle example](docs/circle.png)

```nim
import shady, vmath, shady/demo

# both CPU and GPU code:
proc circleSmooth(fragColor: var Vec4, uv: Vec2, time: Uniform[float32]) =
  var a = 0.0
  var radius = 300.0 + 100 * sin(time)
  for x in 0 ..< 8:
    for y in 0 ..< 8:
      if (uv + vec2(x.float32 - 4.0, y.float32 - 4.0) / 8.0).length < radius:
        a += 1
  a = a / (8 * 8)
  fragColor = vec4(a, a, a, 1)

# test on the CPU:
var testColor: Vec4
circleSmooth(testColor, vec2(100, 100), 0.0)
echo testColor

# compile to a GPU shader:
var shader = toGLSL(circleSmooth)
echo shader

# run the GPU shader and display it in a window:
run("Circle", shader)
```

[See the source](examples/circle.nim)

![mandelbrot example](docs/mandelbrot.png)

[See the source](examples/mandelbrot.nim)

![colors example](docs/colors.png)

[See the Source](examples/colors.nim)

![flare example](docs/flare.png)

[See the Source](examples/flare.nim)


# Using Shady as a shader generator:

![triangle example](docs/triangle.png)

[See the source](examples/triangle.nim)

Nim vertex shader:
```nim
proc basicVert(
  gl_Position: var Vec4,
  MVP: Uniform[Mat4],
  vCol: Vec3,
  vPos: Vec3,
  vertColor: var Vec3
) =
  gl_Position = MVP * vec4(vPos.x, vPos.y, 0.0, 1.0)
  vertColor = vCol
```

GLSL output:
```glsl
#version 410
precision highp float;

uniform mat4 MVP;
attribute vec3 vCol;
attribute vec3 vPos;
out vec3 vertColor;

void main() {
  gl_Position = MVP * vec4(vPos.x, vPos.y, 0.0, 1.0);
  vertColor = vCol;
}
```

Nim fragment shader:
```nim
proc basicFrag(fragColor: var Vec4, vertColor: Vec3) =
  fragColor = vec4(vertColor.x, vertColor.y, vertColor.z, 1.0)
```

GLSL output:
```glsl
#version 410
precision highp float;

in vec3 vertColor;

void main() {
  gl_FragColor = vec4(vertColor.x, vertColor.y, vertColor.z, 1.0);
}
```

# Using Shady to write compute shaders:

Shady can be used to write compute shaders. Compute shaders allow more general purpose code execution work in parallel and are often faster than the CPU for this kind of workload.

```nim
# Setup the uniforms.
var inputCommandBuffer*: Uniform[SamplerBuffer]
var outputImageBuffer*: UniformWriteOnly[UImageBuffer]
var dimensions*: Uniform[IVec4] # ivec4(width, height, 0, 0)

# The shader itself.
proc commandsToImage() =
  var pos = gl_GlobalInvocationID
  for x in 0 ..< dimensions.x:
    pos.x = x.uint32
    let value = uint32(texelFetch(inputCommandBuffer, int32(pos.x)).x)
    #echo pos.x, " ", value
    let colorValue = uvec4(
      128,
      0,
      value,
      255
    )
    imageStore(outputImageBuffer, int32(pos.y * uint32(dimensions.x) + pos.x), colorValue)
```

#### GPU:

![flare example](examples/compute1_output_gpu.png)

#### CPU:

![flare example](examples/compute1_output_cpu.png)

[See the Source](examples/compute1.nim)
