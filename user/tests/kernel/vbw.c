// SPDX-License-Identifier: MIT
// vbw: CPU write/read speed into a mapped CPU-visible VRAM BO and a system-memory BO (cache mode check).
//   clang -arch x86_64 -O2 -I../uapi -o vbw vbw.c -framework IOKit
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <string.h>
#include "xe_drm.h"

static io_connect_t conn;
static int xioctl(unsigned long req, void *arg) {
	uint64_t in[2] = {req, (uint64_t)(uintptr_t)arg}, out = 0;
	uint32_t n = 1;
	if (IOConnectCallScalarMethod(conn, 0, in, 2, &out, &n)) return -1;
	return out ? (int)out : 0;
}
static double secs(uint64_t t) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return (double)t * tb.numer / tb.denom / 1e9; }

static void run(const char *name, uint32_t placement, uint32_t flags, uint16_t caching, IOOptionBits cache) {
	const size_t sz = 16 << 20;
	struct drm_xe_gem_create g = {.size = sz, .placement = placement, .cpu_caching = caching, .flags = flags};
	if (xioctl(DRM_IOCTL_XE_GEM_CREATE, &g)) { printf("%s: create failed\n", name); return; }
	mach_vm_address_t va = 0; mach_vm_size_t len = 0;
	if (IOConnectMapMemory64(conn, g.handle, mach_task_self(), &va, &len, kIOMapAnywhere | cache)) { printf("%s: map failed\n", name); return; }
	volatile uint32_t *p = (volatile uint32_t *)va;
	uint64_t t0 = mach_absolute_time();
	for (size_t i = 0; i < sz / 4; i++) p[i] = (uint32_t)i;
	double w = secs(mach_absolute_time() - t0);
	t0 = mach_absolute_time();
	uint32_t s = 0;
	for (size_t i = 0; i < (1 << 20) / 4; i++) s += p[i];   // 1 MB read
	double r = secs(mach_absolute_time() - t0);
	printf("%-16s write %8.1f MB/s, read %8.1f MB/s (%u)\n", name, sz / w / 1e6, (1 << 20) / r / 1e6, s & 1);
}

int main(void) {
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { fprintf(stderr, "no IntelXe service\n"); return 1; }
	run("VRAM default map", 2, DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM, DRM_XE_GEM_CPU_CACHING_WC, 0);
	run("VRAM WC map", 2, DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM, DRM_XE_GEM_CPU_CACHING_WC, kIOMapWriteCombineCache);
	run("system WB", 1, 0, DRM_XE_GEM_CPU_CACHING_WB, 0);
	return 0;
}
