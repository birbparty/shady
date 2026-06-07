## PICA200 geometry-shader backend tests (Nintendo 3DS, toGeoPica).
##
## Reproduces the devkitPro `geoshader` example (triangle -> 3 midpoint
## sub-triangles, GSH_POINT mode). Substantive structural asserts run everywhere;
## the picasso oracle (assemble the gsh paired with a pass-through vsh into a
## two-DVLE shbin) self-skips when picasso is absent, so the file is CI-safe.

import std/[os, osproc, strutils]
import shady, vmath

type GeoVertex = object
  position: Vec4
  color: Vec4

proc subdivideGeo(prim: Primitive[3, GeoVertex], projection: Uniform[Mat4]) =
  let m0 = (prim[0].position + prim[1].position) * 0.5
  let m1 = (prim[1].position + prim[2].position) * 0.5
  let m2 = (prim[2].position + prim[0].position) * 0.5
  emitVertex(projection * prim[0].position, prim[0].color)
  emitVertex(projection * m0, prim[1].color)
  emitVertex(projection * m2, prim[2].color)
  endPrimitive()
  emitVertex(projection * m0, prim[0].color)
  emitVertex(projection * prim[1].position, prim[1].color)
  emitVertex(projection * m1, prim[2].color)
  endPrimitive()
  emitVertex(projection * m2, prim[0].color)
  emitVertex(projection * m1, prim[1].color)
  emitVertex(projection * prim[2].position, prim[2].color)
  endPrimitive()

const geo = toGeoPica(subdivideGeo)

# A pass-through vertex shader (the other DVLE of the program).
proc passVert(
  gl_Position: var Vec4, inPos: Vec3, inColor: Vec4, vColor: var Vec4
) =
  gl_Position = vec4(inPos.x, inPos.y, inPos.z, 1.0)
  vColor = inColor

const passVsh = toPica(passVert)

block structure:
  # Geometry framing + mode.
  doAssert ".gsh point c0" in geo, geo
  doAssert ".entry gmain" in geo, geo
  doAssert ".fvec projection[4]" in geo, geo
  doAssert ".out outpos position" in geo, geo
  doAssert ".out outclr color" in geo, geo
  # Emission: a 3-triangle subdivision = 9 emits, 3 setemit/index, prim on the
  # LAST emit of each primitive only (3 of them), and the mat4*vec transform.
  doAssert geo.count("\temit\n") == 9, geo
  doAssert geo.count("setemit ") == 9, geo
  doAssert geo.count(", prim") == 3, geo
  doAssert geo.count("setemit 2, prim") == 3, geo   # the closer of each triangle
  doAssert "dp4 outpos.x, projection[0], " in geo, geo
  # Input vertices map to v0..v5 (vertex k: pos=v(2k), color=v(2k+1)).
  doAssert "mov outclr, v1" in geo and "mov outclr, v3" in geo and
           "mov outclr, v5" in geo, geo

block picassoOracle:
  let picasso = findExe("picasso")
  if picasso.len == 0:
    echo "picasso not found — skipping two-DVLE assemble oracle"
  else:
    let dir = getTempDir()
    let vp = dir / "shady_geo_pass.v.pica"
    let gp = dir / "shady_geo_subdiv.g.pica"
    let outp = dir / "shady_geo.shbin"
    writeFile(vp, passVsh)
    writeFile(gp, geo)
    # One picasso invocation, vsh first -> DVLE[0]=vsh, DVLE[1]=gsh.
    let (msg, code) = execCmdEx(picasso & " " & quoteShell(vp) & " " &
      quoteShell(gp) & " -o " & quoteShell(outp))
    doAssert code == 0, "picasso rejected the geometry program:\n" & msg &
      "\n--- gsh ---\n" & geo
    doAssert fileExists(outp) and getFileSize(outp) > 0
    for f in [vp, gp, outp]: removeFile(f)
    echo "picasso assembled the two-DVLE geometry program (vsh + gsh)"

echo "PICA200 geometry shader tests passed"
