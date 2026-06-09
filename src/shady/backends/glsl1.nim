const
  glsl1WebGLVersion* = "100"
  ## GLSL ES 1.00 precision is stage-dependent: the fragment stage has no default
  ## float precision (so the line is mandatory), while the vertex stage defaults to
  ## highp. mediump is chosen for portable GLES2 fragment output (highp in the
  ## fragment stage needs the optional GL_FRAGMENT_PRECISION_HIGH capability).
  glsl1WebGLFragmentExtra* = "precision mediump float;\n"
  glsl1WebGLVertexExtra* = ""
