// SPDX-License-Identifier: MIT
// memq: B580 VRAM usage as the xe memory-region query reports it (total, used, CPU-visible window, its use).
//   clang -arch x86_64 -O1 -I../uapi -o memq memq.c -framework IOKit
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include "xe_drm.h"

static io_connect_t conn;

static int xioctl(unsigned long req, void *arg) {
	uint64_t in[2] = {req, (uint64_t)(uintptr_t)arg}, out = 0;
	uint32_t n = 1;
	if (IOConnectCallScalarMethod(conn, 0, in, 2, &out, &n)) return -1;
	return out ? -1 : 0;
}

int main(void) {
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { fprintf(stderr, "no IntelXe service\n"); return 1; }
	struct drm_xe_device_query q = {.query = DRM_XE_DEVICE_QUERY_MEM_REGIONS};
	if (xioctl(DRM_IOCTL_XE_DEVICE_QUERY, &q)) return 1;
	struct drm_xe_query_mem_regions *m = calloc(1, q.size);
	q.data = (uint64_t)(uintptr_t)m;
	if (xioctl(DRM_IOCTL_XE_DEVICE_QUERY, &q)) return 1;
	for (unsigned i = 0; i < m->num_mem_regions; i++) {
		struct drm_xe_mem_region *r = &m->mem_regions[i];
		printf("%s: total %llu MB, used %llu MB, cpu-visible %llu MB, visible used %llu MB\n",
		       r->mem_class == DRM_XE_MEM_REGION_CLASS_VRAM ? "VRAM" : "SYSMEM",
		       r->total_size >> 20, r->used >> 20, r->cpu_visible_size >> 20, r->cpu_visible_used >> 20);
	}
	return 0;
}
