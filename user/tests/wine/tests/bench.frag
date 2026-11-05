// SPDX-License-Identifier: MIT
#version 450
layout(location=0) in vec2 uv;
layout(location=0) out vec4 color;
layout(push_constant) uniform PC { float t; int iters; } pc;
void main() {
    vec2 p = uv;
    vec3 c = vec3(0.0);
    for (int i = 0; i < pc.iters; i++) {
        p = fract(p * 1.37 + sin(p.yx * 3.1 + pc.t));
        c += vec3(p, p.x * p.y) * 0.02;
    }
    color = vec4(fract(c + vec3(uv, 0.5)), 1.0);
}
