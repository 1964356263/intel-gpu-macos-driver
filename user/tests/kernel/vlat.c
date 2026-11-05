// SPDX-License-Identifier: MIT
// vlat: latency of one CPU read from a WC-mapped CPU-visible VRAM BO, as a function of how long the device was left
// alone before it (PCIe link / package power states), next to a system-memory BO. Measurement only.
//   clang -arch x86_64 -O2 -I../uapi -o vlat vlat.c -framework IOKit
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "xe_drm.h"

static io_connect_t conn;
static int xioctl(unsigned long req, void *arg) {
	uint64_t in[2] = {req, (uint64_t)(uintptr_t)arg}, out = 0;
	uint32_t n = 1;
	if (IOConnectCallScalarMethod(conn, 0, in, 2, &out, &n)) return -1;
	return out ? (int)out : 0;
}
static mach_timebase_info_data_t tb;
static double us(uint64_t t) { return (double)t * tb.numer / tb.denom / 1e3; }
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

static volatile uint32_t *map(uint32_t placement, uint32_t flags, uint16_t caching) {
	struct drm_xe_gem_create g = {.size = 1 << 20, .placement = placement, .cpu_caching = caching, .flags = flags};
	if (xioctl(DRM_IOCTL_XE_GEM_CREATE, &g)) return NULL;
	mach_vm_address_t va = 0; mach_vm_size_t len = 0;
	if (IOConnectMapMemory64(conn, g.handle, mach_task_self(), &va, &len, kIOMapAnywhere | kIOMapWriteCombineCache)) return NULL;
	return (volatile uint32_t *)va;
}

static void spin_us(double d) {
	uint64_t t0 = mach_absolute_time();
	while (us(mach_absolute_time() - t0) < d) __asm__ volatile("pause");
}

int main(int argc, char **argv) {
	mach_timebase_info(&tb);
	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
	if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { fprintf(stderr, "no IntelXe service\n"); return 1; }
	volatile uint32_t *v = map(2, DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM, DRM_XE_GEM_CPU_CACHING_WC);
	if (!v) { fprintf(stderr, "map failed\n"); return 1; }
	for (int i = 0; i < 4096; i++) v[i] = i;
	if (argc > 2 && !strcmp(argv[1], "keep")) {   // keep <seconds> [period_us]: one VRAM read every period (default 20 us)
		double secs = atof(argv[2]), per = argc > 3 ? atof(argv[3]) : 20; uint64_t t0 = mach_absolute_time(); long n = 0; double worst = 0;
		while (us(mach_absolute_time() - t0) < secs * 1e6) {
			uint64_t a = mach_absolute_time(); (void)v[0]; double d = us(mach_absolute_time() - a); if (d > worst) worst = d;
			n++; spin_us(per);
		}
		printf("keep: %ld reads, worst %.1f us\n", n, worst);
		return 0;
	}
	double gaps[] = {0, 5, 20, 50, 100, 200, 500, 1000, 5000};
	const int N = 200;
	double s[N];
	printf("one 4-byte read from WC VRAM after the device sat idle for <gap> us (CPU spinning, so no CPU C-state)\n");
	for (int g = 0; g < 9; g++) {
		for (int i = 0; i < N; i++) {
			spin_us(gaps[g]);
			uint64_t t0 = mach_absolute_time();
			(void)v[(i * 64) & 4095];
			s[i] = us(mach_absolute_time() - t0);
		}
		qsort(s, N, sizeof *s, dcmp);
		double second;
		{ uint64_t t0 = mach_absolute_time(); (void)v[0]; (void)v[16]; second = us(mach_absolute_time() - t0) / 2; }
		printf("  gap %6.0f us: read p50 %6.2f us  p90 %6.2f  max %6.2f   (back-to-back reads right after: %.2f us each)\n",
		       gaps[g], s[N / 2], s[N * 9 / 10], s[N - 1], second);
	}
	// streaming: 64 consecutive 8-byte reads (one descriptor-pool free-list pop is a few of these)
	uint64_t t0 = mach_absolute_time();
	volatile uint64_t *v8 = (volatile uint64_t *)v; uint64_t acc = 0;
	for (int i = 0; i < 1024; i++) acc += v8[i];
	printf("  1024 back-to-back 8-byte reads: %.2f us each (%llu)\n", us(mach_absolute_time() - t0) / 1024, (unsigned long long)(acc & 1));
	t0 = mach_absolute_time();
	for (int i = 0; i < 1024; i++) v8[i] = i;
	printf("  1024 back-to-back 8-byte writes: %.3f us each\n", us(mach_absolute_time() - t0) / 1024);
	return 0;
}
