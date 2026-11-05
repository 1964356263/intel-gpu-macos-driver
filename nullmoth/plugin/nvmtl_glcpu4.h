// glcpu4: the Apple OpenGL CPU pieces, each switchable on its own in the same binary (default on).
//
//   NVMTL_GLCPU4=0            every speed piece below off (the prod7 path), unless a piece's own variable says otherwise;
//                             prod8: not NVMTL_UNCOMMITTED_HANDLERS
//   NVMTL_HANDLER_ARENA=0|1   glcpu3: helper-free completed handlers copied into the command buffer's arena (nvmtl_handler_arena.h)
//   NVMTL_VB_ADDR=0|1         vertex buffers bound by device address (vkCmdBindVertexBuffers3KHR, VK_KHR_device_address_commands)
//   NVMTL_RESREF_BORROW=0|1   resource-set membership and residency counts without transient ARC retain/release pairs
//   NVMTL_VRAM_TAG_ASYNC=0|1  the per-frame IOSurface VRAM generation tag written off the committing thread
//   NVMTL_UNCOMMITTED_HANDLERS=0|1  a command buffer released without being committed runs its scheduled and completed
//                             handlers at release, as Apple's driver does (a contract fix, not a speed piece)
//
// A piece reads its variable once per process (first use) and logs its state. Unset: a speed piece follows NVMTL_GLCPU4
// (unset = on).
// prod8: the contract fix (NVMTL_UNCOMMITTED_HANDLERS, NVMTL_G4_FIX) no longer follows NVMTL_GLCPU4: it is on unless its own
// variable is 0, so NVMTL_GLCPU4=0 is "the four speed pieces off" and an A/B of them keeps Apple's handler contract on
// both sides.
#include <stdlib.h>
void nvlog(const char *fmt, ...);
static int nvmtl_g4_read_ex(const char *env, const char *what, int follows_master) {
    const char *e = getenv(env), *m = getenv("NVMTL_GLCPU4");
    const int on = (e && *e) ? e[0] != '0' : !(follows_master && m && m[0] == '0');
    nvlog("glcpu4: %s %s (%s=%s, NVMTL_GLCPU4=%s%s)", what, on ? "ON" : "off", env, e ? e : "unset", m ? m : "unset",
          follows_master ? "" : ", not followed: contract fix");
    return on;
}
static int nvmtl_g4_read(const char *env, const char *what) { return nvmtl_g4_read_ex(env, what, 1); }
#define NVMTL_G4_SWITCH(fn, env, what) \
    static int fn(void) { static int v = -1; if (__builtin_expect(v < 0, 0)) v = nvmtl_g4_read(env, what); return v; }
#define NVMTL_G4_FIX(fn, env, what) \
    static int fn(void) { static int v = -1; if (__builtin_expect(v < 0, 0)) v = nvmtl_g4_read_ex(env, what, 0); return v; }
