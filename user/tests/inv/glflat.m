// SPDX-License-Identifier: MIT
// glflat: GL last-vertex provoking check (flat varying, per-vertex colours red/green/blue; GL says blue), short and byte
// indices, triangles and a 2-triangle strip. Based on glidx.
// glidx: Apple's GL on the plugin with Minecraft's draw shapes. An offscreen 2560x1302 RGBA8 + depth FBO, N draws per
// frame of small quads indexed with GL_UNSIGNED_BYTE (Apple's GL converts those with a fixIndexBuffer compute dispatch)
// or GL_UNSIGNED_SHORT. Frame time by glFinish, best of 10 frames.
//   glidx [N] [byte|short]
#import <AppKit/AppKit.h>
#import <OpenGL/gl3.h>
#import <Metal/Metal.h>
#define PICK_GL
#include "pickdev.h"
#include <mach/mach_time.h>
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6; }
static GLuint sh(GLenum t, const char *s) { GLuint o = glCreateShader(t); glShaderSource(o, 1, &s, NULL); glCompileShader(o); GLint ok; glGetShaderiv(o, GL_COMPILE_STATUS, &ok);
    if (!ok) { char l[1024]; glGetShaderInfoLog(o, sizeof l, NULL, l); printf("shader: %s\n", l); } return o; }
int main(int argc, char **argv) { @autoreleasepool {
    const char *bp = getenv("NVMTL_BUNDLE");
    if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u);
              printf("preload %s: %s\n", bp, b && CFBundleLoadExecutable(b) ? "loaded" : "FAILED"); }
    (void)mtl_pick_intelxe();   // as hitchtest: the Metal device first, then Apple's GL renderer over it
    const int N = argc > 1 ? atoi(argv[1]) : 500; const int byte = !(argc > 2 && !strcmp(argv[2], "short"));
    NSOpenGLPixelFormatAttribute at[] = { NSOpenGLPFAAccelerated, NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion4_1Core, 0 };
    (void)at; NSOpenGLContext *ctx = gl_pick_intelxe();   // the renderer over the B580, not the iGPU's
    if (!ctx) { printf("no GL context\n"); return 1; } [ctx makeCurrentContext];
    printf("GL: %s\n", glGetString(GL_RENDERER));
    GLuint fbo, cr, dr; glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glGenRenderbuffers(1, &cr); glBindRenderbuffer(GL_RENDERBUFFER, cr); glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 2560, 1302);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, cr);
    glGenRenderbuffers(1, &dr); glBindRenderbuffer(GL_RENDERBUFFER, dr); glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, 2560, 1302);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, dr);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { printf("fbo incomplete\n"); return 1; }
    glViewport(0, 0, 2560, 1302); glEnable(GL_DEPTH_TEST);
    GLuint pr = glCreateProgram();
    glAttachShader(pr, sh(GL_VERTEX_SHADER, "#version 410\nlayout(location=0) in vec2 p; layout(location=1) in vec3 col; flat out vec3 fc; uniform vec2 o; void main() { fc = col; gl_Position = vec4(p + o, 0.5, 1); }"));
    glAttachShader(pr, sh(GL_FRAGMENT_SHADER, "#version 410\nflat in vec3 fc; out vec4 c; void main() { c = vec4(fc, 1); }"));
    glLinkProgram(pr); glUseProgram(pr); GLint uo = glGetUniformLocation(pr, "o");
    GLuint vao, vb, ib; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    const float v[20] = { -1,-1, 1,0,0,  1,-1, 0,1,0,  1,1, 0,0,1,  -1,1, 1,1,0 };
    glGenBuffers(1, &vb); glBindBuffer(GL_ARRAY_BUFFER, vb); glBufferData(GL_ARRAY_BUFFER, sizeof v, v, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 20, 0);
    glEnableVertexAttribArray(1); glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 20, (void *)8);
    const unsigned char i8[6] = { 0, 1, 2, 0, 2, 3 }; const unsigned short i16[6] = { 0, 1, 2, 0, 2, 3 };
    glGenBuffers(1, &ib); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ib);
    if (byte) glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof i8, i8, GL_STATIC_DRAW); else glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof i16, i16, GL_STATIC_DRAW);
    glUniform2f(uo, 0, 0);
    // triangles 0,1,2 and 0,2,3: provoking (last) = 2 (blue) and 3 (yellow). Sample inside each: (0.6,-0.6) in tri 1, (-0.6,0.6) in tri 2
    glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glDrawElements(GL_TRIANGLES, 6, byte ? GL_UNSIGNED_BYTE : GL_UNSIGNED_SHORT, 0); glFinish();
    unsigned char a[4], b[4]; glReadPixels((int)(2560 * 0.8), (int)(1302 * 0.2), 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, a); glReadPixels((int)(2560 * 0.2), (int)(1302 * 0.8), 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, b);
    const int ok = a[0] < 20 && a[1] < 20 && a[2] > 230 && b[0] > 230 && b[1] > 230 && b[2] < 20;
    printf("%s %s indices: triangle 1 %u,%u,%u (want blue), triangle 2 %u,%u,%u (want yellow)\n", ok ? "PASS" : "FAIL", byte ? "byte" : "short", a[0], a[1], a[2], b[0], b[1], b[2]);
    (void)N; (void)now_ms;
} return 0; }
