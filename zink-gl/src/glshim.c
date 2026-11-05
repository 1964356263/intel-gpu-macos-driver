/* libGLzink: an "OpenGL library" for LWJGL (-Dorg.lwjgl.opengl.libname). LWJGL resolves every GL function
 * through OSMesaGetProcAddress when the library exports it; this one forwards to Mesa's eglGetProcAddress. */
#include <EGL/egl.h>
__attribute__((visibility("default"))) void *OSMesaGetProcAddress(const char *name) { return (void *)eglGetProcAddress(name); }
