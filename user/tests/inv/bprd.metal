// SPDX-License-Identifier: MIT
#include <metal_stdlib>
using namespace metal;
kernel void rd(texture2d<float, access::read> t [[texture(0)]], device uint *o [[buffer(0)]], constant uint &w [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
  if (g.x >= t.get_width() || g.y >= t.get_height()) return;
  float4 c = t.read(g); o[g.y * w + g.x] = pack_float_to_unorm4x8(float4(c.b, c.g, c.r, c.a)); }
