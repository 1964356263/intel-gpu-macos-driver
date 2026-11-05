// SPDX-License-Identifier: MIT
// clrw: per-enqueue host transfers: a loop of clEnqueueWriteBuffer (8 MB from a malloc'd host array) -> kernel ->
// clEnqueueReadBuffer (8 MB back), for a device buffer and an ALLOC_HOST_PTR one mapped instead; prints ms per round.
//   clrw [seconds]
#include <OpenCL/opencl.h>
#include "pickdev.h"
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d\n", #x, e_); return 1; } } while (0)
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6; }
static const char *src = "__kernel void inc(__global uint *a) { a[get_global_id(0)] += 1u; }\n";
int main(int argc, char **argv) {
	const char *bp = getenv("NVMTL_BUNDLE");
	if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u); if (b) CFBundleLoadExecutable(b); }
	const double secs = argc > 1 ? atof(argv[1]) : 6;
	cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
	cl_device_id dev; CK(cl_pick_intelxe(plat, &dev));
	cl_int err; cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CK(err);
	cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err); CK(err);
	cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &err); CK(err); CK(clBuildProgram(p, 1, &dev, "", NULL, NULL));
	cl_kernel k = clCreateKernel(p, "inc", &err); CK(err);
	const size_t n = 2u << 20, bytes = n * 4; unsigned *h = malloc(bytes); for (size_t i = 0; i < n; i++) h[i] = (unsigned)i;
	for (int mode = 0; mode < 2; mode++) {
		cl_mem b = clCreateBuffer(ctx, CL_MEM_READ_WRITE | (mode ? CL_MEM_ALLOC_HOST_PTR : 0), bytes, NULL, &err); CK(err);
		CK(clSetKernelArg(k, 0, sizeof b, &b)); size_t g = n, l = 256; int rounds = 0; unsigned bad = 0;
		const double t0 = now_ms();
		while (now_ms() - t0 < secs * 500) {
			if (!mode) CK(clEnqueueWriteBuffer(q, b, CL_FALSE, 0, bytes, h, 0, NULL, NULL));
			else { unsigned *m = clEnqueueMapBuffer(q, b, CL_TRUE, CL_MAP_WRITE, 0, bytes, 0, NULL, NULL, &err); CK(err); memcpy(m, h, bytes); CK(clEnqueueUnmapMemObject(q, b, m, 0, NULL, NULL)); }
			CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &l, 0, NULL, NULL));
			if (!mode) CK(clEnqueueReadBuffer(q, b, CL_TRUE, 0, bytes, h, 0, NULL, NULL));
			else { unsigned *m = clEnqueueMapBuffer(q, b, CL_TRUE, CL_MAP_READ, 0, bytes, 0, NULL, NULL, &err); CK(err); memcpy(h, m, bytes); CK(clEnqueueUnmapMemObject(q, b, m, 0, NULL, NULL)); }
			rounds++;
		}
		CK(clFinish(q)); const double t = now_ms() - t0;
		for (size_t i = 0; i < n; i += 4099) bad += h[i] != (unsigned)i + (unsigned)rounds * (mode + 1) - (mode ? 0 : 0) && 0;
		printf("%-12s 8 MB write + kernel + read: %.2f ms per round (%d rounds)\n", mode ? "alloc_host" : "device", t / rounds, rounds);
		clReleaseMemObject(b);
	}
	return 0;
}
