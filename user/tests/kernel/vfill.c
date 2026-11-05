// SPDX-License-Identifier: MIT
// vfill: fills the CPU-visible VRAM window past its end with N MB of NEEDS_VISIBLE, VRAM-only BOs (64 MB each), maps
// every one and checks a CPU write/read pattern, so the kernel's system-memory fallback for a full window can be tested.
//   clang -arch x86_64 -O1 -I../uapi -o vfill vfill.c -framework IOKit
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include "xe_drm.h"

static io_connect_t conn;

static int xioctl(unsigned long req, void *arg) {
	uint64_t in[2] = {req, (uint64_t)(uintptr_t)arg}, out = 0;
	uint32_t n = 1;
	if (IOConnectCallScalarMethod(conn, 0, in, 2, &out, &n)) return -1;
	return out ? (int)out : 0;
}

int main(int argc, char **argv) {
	unsigned mb = argc > 1 ? (unsigned)atoi(argv[1]) : 1152, bad = 0, made = 0;
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { fprintf(stderr, "no IntelXe service\n"); return 1; }
	for (unsigned i = 0; i < mb / 64; i++) {
		struct drm_xe_gem_create g = {.size = 64ull << 20, .placement = 2, .cpu_caching = DRM_XE_GEM_CPU_CACHING_WC,
		                              .flags = DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM};
		int e = xioctl(DRM_IOCTL_XE_GEM_CREATE, &g);
		if (e) { printf("BO %u: GEM_CREATE error %d\n", i, e); bad++; continue; }
		mach_vm_address_t va = 0; mach_vm_size_t len = 0;
		if (IOConnectMapMemory64(conn, g.handle, mach_task_self(), &va, &len, kIOMapAnywhere)) {
			printf("BO %u: map failed\n", i); bad++; continue;
		}
		volatile uint64_t *p = (volatile uint64_t *)va;
		for (uint64_t o = 0; o < len / 8; o += 4096) p[o] = (uint64_t)i << 32 | o;
		for (uint64_t o = 0; o < len / 8; o += 4096) if (p[o] != ((uint64_t)i << 32 | o)) { bad++; printf("BO %u: readback mismatch\n", i); break; }
		made++;
	}
	printf("%u x 64 MB BOs created and checked, %u failures\n", made, bad);
	struct drm_xe_device_query q = {.query = DRM_XE_DEVICE_QUERY_MEM_REGIONS};
	xioctl(DRM_IOCTL_XE_DEVICE_QUERY, &q);
	struct drm_xe_query_mem_regions *m = calloc(1, q.size);
	q.data = (uint64_t)(uintptr_t)m;
	xioctl(DRM_IOCTL_XE_DEVICE_QUERY, &q);
	for (unsigned i = 0; i < m->num_mem_regions; i++)
		if (m->mem_regions[i].mem_class == DRM_XE_MEM_REGION_CLASS_VRAM)
			printf("VRAM used %llu MB, visible used %llu of %llu MB\n", m->mem_regions[i].used >> 20,
			       m->mem_regions[i].cpu_visible_used >> 20, m->mem_regions[i].cpu_visible_size >> 20);
	return bad != 0;
}
