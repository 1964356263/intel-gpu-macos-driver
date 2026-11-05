/* Offscreen EGL (surfaceless platform) GL 3.2 core test: triangle into a pbuffer, read back, time N frames. */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dlfcn.h>

typedef unsigned int GLenum; typedef unsigned int GLuint; typedef int GLint; typedef int GLsizei;
typedef float GLfloat; typedef unsigned char GLubyte; typedef char GLchar; typedef long GLsizeiptr; typedef unsigned int GLbitfield;
#define GL_TRIANGLES 4
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_ARRAY_BUFFER 0x8892
#define GL_STATIC_DRAW 0x88E4
#define GL_FLOAT 0x1406
#define GL_FALSE 0
#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_RGBA 0x1908
#define GL_UNSIGNED_BYTE 0x1401
#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C

#define F(ret, name, args) static ret (*name) args;
#define GLFUNCS \
 F(const GLubyte*, glGetString, (GLenum)) F(void, glClearColor, (GLfloat,GLfloat,GLfloat,GLfloat)) F(void, glClear, (GLbitfield)) \
 F(void, glViewport, (GLint,GLint,GLsizei,GLsizei)) F(void, glGenVertexArrays, (GLsizei,GLuint*)) F(void, glBindVertexArray, (GLuint)) \
 F(void, glGenBuffers, (GLsizei,GLuint*)) F(void, glBindBuffer, (GLenum,GLuint)) F(void, glBufferData, (GLenum,GLsizeiptr,const void*,GLenum)) \
 F(void, glVertexAttribPointer, (GLuint,GLint,GLenum,unsigned char,GLsizei,const void*)) F(void, glEnableVertexAttribArray, (GLuint)) \
 F(GLuint, glCreateShader, (GLenum)) F(void, glShaderSource, (GLuint,GLsizei,const GLchar*const*,const GLint*)) F(void, glCompileShader, (GLuint)) \
 F(void, glGetShaderiv, (GLuint,GLenum,GLint*)) F(void, glGetShaderInfoLog, (GLuint,GLsizei,GLsizei*,GLchar*)) F(GLuint, glCreateProgram, (void)) \
 F(void, glAttachShader, (GLuint,GLuint)) F(void, glLinkProgram, (GLuint)) F(void, glGetProgramiv, (GLuint,GLenum,GLint*)) F(void, glUseProgram, (GLuint)) \
 F(void, glDrawArrays, (GLenum,GLint,GLsizei)) F(void, glFinish, (void)) F(void, glReadPixels, (GLint,GLint,GLsizei,GLsizei,GLenum,GLenum,void*)) \
 F(GLenum, glGetError, (void)) F(GLint, glGetUniformLocation, (GLuint,const GLchar*)) F(void, glUniform1f, (GLint,GLfloat)) F(void, glBindFramebuffer, (GLenum,GLuint))
GLFUNCS
#undef F

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

static GLuint shader(GLenum type, const char *src) {
   GLuint s = glCreateShader(type); glShaderSource(s, 1, &src, NULL); glCompileShader(s);
   GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) { char log[2048]; glGetShaderInfoLog(s, sizeof log, NULL, log); fprintf(stderr, "shader: %s\n", log); exit(1); }
   return s;
}

int main(int argc, char **argv) {
   int frames = argc > 1 ? atoi(argv[1]) : 1000;
   const int W = 1920, H = 1080;
   PFNEGLGETPLATFORMDISPLAYEXTPROC gpd = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
   int native = argc > 2 && !strcmp(argv[2], "native");
   EGLDisplay dpy = (gpd && !native) ? gpd(EGL_PLATFORM_SURFACELESS_MESA, NULL, NULL) : eglGetDisplay(EGL_DEFAULT_DISPLAY);
   printf("display: %s\n", (gpd && !native) ? "surfaceless" : "EGL_DEFAULT_DISPLAY (native platform)");
   EGLint maj, min;
   if (!eglInitialize(dpy, &maj, &min)) { fprintf(stderr, "eglInitialize failed 0x%x\n", eglGetError()); return 1; }
   printf("EGL %d.%d %s / %s\n", maj, min, eglQueryString(dpy, EGL_VENDOR), eglQueryString(dpy, EGL_VERSION));
   if (!eglBindAPI(EGL_OPENGL_API)) { fprintf(stderr, "bind api\n"); return 1; }
   EGLint ca[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24, EGL_NONE };
   EGLConfig cfg; EGLint n = 0;
   if (!eglChooseConfig(dpy, ca, &cfg, 1, &n) || n < 1) { fprintf(stderr, "no config 0x%x\n", eglGetError()); return 1; }
   EGLint cx[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 2, EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
                   EGL_CONTEXT_OPENGL_FORWARD_COMPATIBLE, EGL_TRUE, EGL_NONE };
   EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, cx);
   if (!ctx) { fprintf(stderr, "context 0x%x\n", eglGetError()); return 1; }
   EGLint pa[] = { EGL_WIDTH, W, EGL_HEIGHT, H, EGL_NONE };
   EGLSurface pb = eglCreatePbufferSurface(dpy, cfg, pa);
   if (!pb) { fprintf(stderr, "pbuffer 0x%x\n", eglGetError()); return 1; }
   if (!eglMakeCurrent(dpy, pb, pb, ctx)) { fprintf(stderr, "make current 0x%x\n", eglGetError()); return 1; }
   void *(*gpa)(const char *) = (void *(*)(const char *))eglGetProcAddress;
   if (getenv("EGLTRI_SHIM")) { void *h = dlopen(getenv("EGLTRI_SHIM"), RTLD_NOW); gpa = h ? (void *(*)(const char *))dlsym(h, "OSMesaGetProcAddress") : NULL; if (!gpa) { fprintf(stderr, "shim\n"); return 1; } printf("GL via shim OSMesaGetProcAddress\n"); }
#define F(ret, name, args) name = (ret (*) args)gpa(#name); if (!name) { fprintf(stderr, "missing %s\n", #name); return 1; }
   GLFUNCS
#undef F
   printf("GL_VENDOR   %s\nGL_RENDERER %s\nGL_VERSION  %s\nGLSL        %s\n", glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION));
   const char *vs = "#version 150\nin vec2 p; uniform float t; void main(){ float c=cos(t), s=sin(t); gl_Position=vec4(c*p.x-s*p.y, s*p.x+c*p.y, 0, 1); }\n";
   const char *fs = "#version 150\nout vec4 o; void main(){ o = vec4(1.0, 0.5, 0.0, 1.0); }\n";
   GLuint prog = glCreateProgram(); glAttachShader(prog, shader(GL_VERTEX_SHADER, vs)); glAttachShader(prog, shader(GL_FRAGMENT_SHADER, fs)); glLinkProgram(prog);
   GLint ok = 0; glGetProgramiv(prog, GL_LINK_STATUS, &ok); if (!ok) { fprintf(stderr, "link\n"); return 1; }
   glUseProgram(prog); GLint ut = glGetUniformLocation(prog, "t");
   GLuint vao, vbo; glGenVertexArrays(1, &vao); glBindVertexArray(vao); glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
   float v[] = { -0.8f, -0.8f, 0.8f, -0.8f, 0.0f, 0.8f }; glBufferData(GL_ARRAY_BUFFER, sizeof v, v, GL_STATIC_DRAW);
   glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0); glEnableVertexAttribArray(0);
   glViewport(0, 0, W, H); glClearColor(0.0f, 0.0f, 0.5f, 1.0f);
   glBindFramebuffer(0x8D40, 0); glClear(GL_COLOR_BUFFER_BIT); glUniform1f(ut, 0.0f); glDrawArrays(GL_TRIANGLES, 0, 3); glFinish();
   unsigned char px[2][4];
   glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px[0]);
   glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px[1]);
   printf("center %u,%u,%u,%u (want 255,128,0,255)  corner %u,%u,%u,%u (want 0,0,128,255)  glGetError 0x%x\n",
          px[0][0], px[0][1], px[0][2], px[0][3], px[1][0], px[1][1], px[1][2], px[1][3], glGetError());
   double t0 = now();
   for (int i = 0; i < frames; i++) { glClear(GL_COLOR_BUFFER_BIT); glUniform1f(ut, i * 0.01f); glDrawArrays(GL_TRIANGLES, 0, 3); if ((i & 63) == 63) glFinish(); }
   glFinish();
   double dt = now() - t0;
   printf("%d frames 1080p clear+tri: %.3f s, %.0f fps\n", frames, dt, frames / dt);
   eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
   eglDestroySurface(dpy, pb); eglDestroyContext(dpy, ctx); eglTerminate(dpy);
   printf("OK\n");
   return 0;
}
