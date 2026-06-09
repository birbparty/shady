## Public switchboard for Shady's shader backends.

import shady/backends/[shared, glsl, glsl1, glsl3, glsl4, dx12, metal4, vulkan]
import shady/backends/tev
import shady/binary

export shared, glsl, glsl1, glsl3, glsl4, dx12, metal4, vulkan, binary
export tev   # PICA200 TEV fragment-config recognizer (Nintendo 3DS)

when not defined(shadyNoPixie):
  # CPU-simulation runtime (image samplers, texture/imageStore on the CPU).
  # Depends on pixie; omit with -d:shadyNoPixie on pixie-less targets (e.g. 3DS
  # shader codegen) so pixie is not compiled into the binary.
  import shady/backends/cpusim
  export cpusim
