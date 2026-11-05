// SPDX-License-Identifier: MIT
// gl_bind: Apple OpenGL (GL 4.1 core over AppleMetalOpenGLRenderer -> our Metal plugin) draw-call benchmark, shaped like
// Minecraft's chunk pass: many small indexed draws, a uniform per draw, VAO and texture switches.
//   ./gl_bind [-n draws] [-f frames] [-o outdir] [-loop sec] [mode...]
// With NVMTL_BUNDLE=<path>/NVMTLDriver.bundle and DYLD_INSERT_LIBRARIES=nvmtl_interpose.dylib, GL runs on that plugin
// build instead of the installed one (nothing installed); the interposer prints which Metal entry points GL called.
// Output per mode: CPU ns per draw (issue loop, p50 over frames), frame ms with glFinish, image FNV hash.
#import <Foundation/Foundation.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <mach/mach_time.h>

static int NDRAW = 2000, NFRAME = 30;
static const char *outdir;
static double now_ns(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom; }
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

#define W 1024
#define NVAO 64
static GLuint prog, progTex2, fbo, rtex, depth, vao[NVAO], vbo[NVAO], ibo, tex[8], ubo;
static GLint uOff, uTint, uOff2, uTint2;

static GLuint sh(GLenum t, const char *s) {
    GLuint o = glCreateShader(t); glShaderSource(o, 1, &s, NULL); glCompileShader(o);
    GLint ok = 0; glGetShaderiv(o, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[2048]; glGetShaderInfoLog(o, sizeof log, NULL, log); printf("shader: %s\n", log); exit(2); }
    return o;
}
static GLuint link2(const char *vs, const char *fs) {
    GLuint p = glCreateProgram(); glAttachShader(p, sh(GL_VERTEX_SHADER, vs)); glAttachShader(p, sh(GL_FRAGMENT_SHADER, fs));
    glBindAttribLocation(p, 0, "pos"); glBindAttribLocation(p, 1, "uv"); glBindAttribLocation(p, 2, "col");
    glLinkProgram(p); GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) { char log[2048]; glGetProgramInfoLog(p, sizeof log, NULL, log); printf("link: %s\n", log); exit(2); }
    return p;
}

static void setup(void) {
    const char *vs =
        "#version 410\n"
        "in vec3 pos; in vec2 uv; in vec4 col;\n"
        "uniform vec3 chunkOffset;\n"
        "layout(std140) uniform Frame { mat4 proj; vec4 fog; };\n"
        "out vec2 vuv; out vec4 vcol;\n"
        "void main() { vuv = uv; vcol = col * fog.x; gl_Position = proj * vec4(pos + chunkOffset, 1.0); }\n";
    const char *fs =
        "#version 410\n"
        "in vec2 vuv; in vec4 vcol; uniform sampler2D tex0; uniform vec4 tint; out vec4 o;\n"
        "void main() { vec4 c = texture(tex0, vuv) * vcol * tint; if (c.a < 0.1) discard; o = c; }\n";
    const char *fs2 =
        "#version 410\n"
        "in vec2 vuv; in vec4 vcol; uniform sampler2D tex0; uniform sampler2D tex1; uniform vec4 tint; out vec4 o;\n"
        "void main() { vec4 c = texture(tex0, vuv) * texture(tex1, vuv * 0.5) * vcol * tint; if (c.a < 0.1) discard; o = c; }\n";
    prog = link2(vs, fs); progTex2 = link2(vs, fs2);
    uOff = glGetUniformLocation(prog, "chunkOffset"); uTint = glGetUniformLocation(prog, "tint");
    uOff2 = glGetUniformLocation(progTex2, "chunkOffset"); uTint2 = glGetUniformLocation(progTex2, "tint");
    glUseProgram(prog); glUniform1i(glGetUniformLocation(prog, "tex0"), 0);
    glUseProgram(progTex2); glUniform1i(glGetUniformLocation(progTex2, "tex0"), 0); glUniform1i(glGetUniformLocation(progTex2, "tex1"), 1);
    glUniformBlockBinding(prog, glGetUniformBlockIndex(prog, "Frame"), 0);
    glUniformBlockBinding(progTex2, glGetUniformBlockIndex(progTex2, "Frame"), 0);
    // frame uniforms: an orthographic projection over a 64x32 grid of 1x1 cells
    float frame[20] = { 2.0f / 64, 0, 0, 0,  0, 2.0f / 32, 0, 0,  0, 0, -0.01f, 0,  -1, -1, 0, 1,  1, 0, 0, 0 };
    glGenBuffers(1, &ubo); glBindBuffer(GL_UNIFORM_BUFFER, ubo); glBufferData(GL_UNIFORM_BUFFER, sizeof frame, frame, GL_STATIC_DRAW);
    glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo);
    // 64 "chunk sections": each a VAO of 4 quads at the cell origin (pos, uv, colour), one shared quad index buffer
    for (int v = 0; v < NVAO; v++) {
        float d[4 * 4 * 9]; int k = 0;
        for (int q = 0; q < 4; q++) {
            const float x0 = (q & 1) * 0.5f, y0 = (q >> 1) * 0.5f, s = 0.45f;
            const float P[4][2] = { { x0, y0 }, { x0 + s, y0 }, { x0 + s, y0 + s }, { x0, y0 + s } };
            for (int c = 0; c < 4; c++) {
                d[k++] = P[c][0]; d[k++] = P[c][1]; d[k++] = 0;
                d[k++] = (c == 1 || c == 2) ? 1.0f : 0.0f; d[k++] = c >= 2 ? 1.0f : 0.0f;
                d[k++] = 0.4f + 0.15f * (v & 3); d[k++] = 0.3f + 0.1f * ((v >> 2) & 3); d[k++] = 0.5f + 0.12f * q; d[k++] = 1.0f;
            }
        }
        glGenVertexArrays(1, &vao[v]); glBindVertexArray(vao[v]);
        glGenBuffers(1, &vbo[v]); glBindBuffer(GL_ARRAY_BUFFER, vbo[v]); glBufferData(GL_ARRAY_BUFFER, sizeof d, d, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0); glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 36, (void *)0);
        glEnableVertexAttribArray(1); glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 36, (void *)12);
        glEnableVertexAttribArray(2); glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, 36, (void *)20);
        if (!v) {
            uint16_t ix[24]; for (int q = 0; q < 4; q++) { const uint16_t b = (uint16_t)(q * 4); const uint16_t t[6] = { b, (uint16_t)(b + 1), (uint16_t)(b + 2), b, (uint16_t)(b + 2), (uint16_t)(b + 3) }; memcpy(ix + q * 6, t, sizeof t); }
            glGenBuffers(1, &ibo); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo); glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof ix, ix, GL_STATIC_DRAW);
        } else glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    }
    glBindVertexArray(0);
    // 8 textures 64x64 with mipmaps (block atlases)
    for (int t = 0; t < 8; t++) {
        uint32_t *px = malloc(64 * 64 * 4);
        for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++)
            px[y * 64 + x] = 0xff000000u | (uint32_t)(((x ^ y) & 8) ? 0xd0 + t * 4 : 0x60) | (uint32_t)((0x40 + t * 20) << 8) | (uint32_t)(((y * 4) & 0xff) << 16);
        glGenTextures(1, &tex[t]); glBindTexture(GL_TEXTURE_2D, tex[t]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, px); free(px);
        glGenerateMipmap(GL_TEXTURE_2D);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (t & 1) ? GL_NEAREST_MIPMAP_LINEAR : GL_LINEAR_MIPMAP_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (t & 1) ? GL_NEAREST : GL_LINEAR);
    }
    glGenTextures(1, &rtex); glBindTexture(GL_TEXTURE_2D, rtex); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, W, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glGenRenderbuffers(1, &depth); glBindRenderbuffer(GL_RENDERBUFFER, depth); glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, W, W);
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rtex, 0);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { printf("FBO incomplete\n"); exit(2); }
    glViewport(0, 0, W, W);
    glEnable(GL_DEPTH_TEST); glDepthFunc(GL_LEQUAL);
    glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
}

// one frame: returns the issue time (clear .. last draw) in ns, *fin = the glFinish time
static double frame(const char *m, double *fin) {
    const int vaoSw = strcmp(m, "uni") != 0, texSw = !strcmp(m, "tex") || !strcmp(m, "mix"), two = !strcmp(m, "mix");
    const int tintSw = !strcmp(m, "mix");
    double t0 = now_ns();
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glClearColor(0.1f, 0.1f, 0.15f, 1); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glUseProgram(two ? progTex2 : prog);
    const GLint uo = two ? uOff2 : uOff, ut = two ? uTint2 : uTint;
    glUniform4f(ut, 1, 1, 1, 1);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, tex[5]);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex[0]);
    glBindVertexArray(vao[0]);
    for (int k = 0; k < NDRAW; k++) {
        if (vaoSw) glBindVertexArray(vao[k & (NVAO - 1)]);
        if (texSw && !(k & 7)) glBindTexture(GL_TEXTURE_2D, tex[(k >> 3) & 7]);
        if (tintSw && !(k & 15)) glUniform4f(ut, 1.0f, 0.9f + 0.1f * ((k >> 4) & 1), 1.0f, 1.0f);
        const int cell = k % (64 * 32);
        glUniform3f(uo, (float)(cell & 63), (float)(cell >> 6), (float)(k / 2048) * 0.001f);
        glDrawElements(GL_TRIANGLES, 24, GL_UNSIGNED_SHORT, 0);
    }
    double t1 = now_ns();
    glFinish();
    *fin = now_ns() - t1;
    return t1 - t0;
}
static uint64_t fnv(const uint8_t *p, size_t n) { uint64_t h = 1469598103934665603ull; for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; } return h; }

static void run(const char *m) {
    double f, *iss = calloc(NFRAME, 8), *fn = calloc(NFRAME, 8), *wl = calloc(NFRAME, 8);
    for (int i = 0; i < 3; i++) frame(m, &f);
    for (int i = 0; i < NFRAME; i++) { double a = now_ns(); iss[i] = frame(m, &fn[i]); wl[i] = now_ns() - a; }
    qsort(iss, NFRAME, 8, dcmp); qsort(fn, NFRAME, 8, dcmp); qsort(wl, NFRAME, 8, dcmp);
    uint8_t *px = malloc(W * W * 4);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glReadPixels(0, 0, W, W, GL_RGBA, GL_UNSIGNED_BYTE, px);
    uint64_t h = fnv(px, W * W * 4);
    if (outdir) { char p[1024]; snprintf(p, sizeof p, "%s/gl-%s.rgba", outdir, m); FILE *o = fopen(p, "wb"); if (o) { fwrite(px, 1, W * W * 4, o); fclose(o); } }
    printf("gl-%-4s issue/draw p50 %6.0f min %6.0f ns | issue/frame p50 %6.2f ms | finish p50 %6.2f ms | frame p50 %6.2f ms = %5.0f fps | GL error 0x%x | hash %016llx\n",
           m, iss[NFRAME / 2] / NDRAW, iss[0] / NDRAW, iss[NFRAME / 2] / 1e6, fn[NFRAME / 2] / 1e6, wl[NFRAME / 2] / 1e6, 1e9 / wl[NFRAME / 2],
           glGetError(), (unsigned long long)h);
    fflush(stdout); free(px); free(iss); free(fn); free(wl);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *modes[16]; int nm = 0; double loop = 0;
        for (int a = 1; a < argc; a++) {
            if (!strcmp(argv[a], "-n") && a + 1 < argc) NDRAW = atoi(argv[++a]);
            else if (!strcmp(argv[a], "-f") && a + 1 < argc) NFRAME = atoi(argv[++a]);
            else if (!strcmp(argv[a], "-o") && a + 1 < argc) outdir = argv[++a];
            else if (!strcmp(argv[a], "-loop") && a + 1 < argc) loop = atof(argv[++a]);
            else if (nm < 16) modes[nm++] = argv[a];
        }
        if (!nm) { modes[nm++] = "uni"; modes[nm++] = "vao"; modes[nm++] = "tex"; modes[nm++] = "mix"; }
        CGLPixelFormatAttribute at[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated,
                                         kCGLPFANoRecovery, kCGLPFAColorSize, (CGLPixelFormatAttribute)24, kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
                                         kCGLPFADepthSize, (CGLPixelFormatAttribute)24, (CGLPixelFormatAttribute)0 };
        CGLPixelFormatObj pf = NULL; GLint npf = 0;
        if (CGLChoosePixelFormat(at, &pf, &npf) || !pf) { printf("no accelerated GL 4.1 pixel format\n"); return 2; }
        CGLContextObj ctx = NULL;
        if (CGLCreateContext(pf, NULL, &ctx) || !ctx) { printf("CGLCreateContext failed\n"); return 2; }
        CGLSetCurrentContext(ctx);
        GLint rid = 0; CGLGetParameter(ctx, kCGLCPCurrentRendererID, &rid);
        printf("GL: %s | %s | renderer 0x%x | draws/frame %d frames %d\n", glGetString(GL_RENDERER), glGetString(GL_VERSION), rid, NDRAW, NFRAME);
        setup();
        if (loop > 0) {
            double end = now_ns() + loop * 1e9, f; long n = 0;
            while (now_ns() < end) { frame(modes[0], &f); n++; }
            printf("loop gl-%s: %ld frames in %.1f s\n", modes[0], n, loop);
            return 0;
        }
        for (int i = 0; i < nm; i++) run(modes[i]);
    }
    return 0;
}
