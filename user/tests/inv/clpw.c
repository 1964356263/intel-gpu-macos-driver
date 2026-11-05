// SPDX-License-Identifier: MIT
// clpw: a partial clEnqueueWriteBuffer (offset 28, 400 bytes) read straight back, per buffer kind
#include <OpenCL/opencl.h>
#include "pickdev.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d\n", #x, e_); return 1; } } while (0)
static int fails;
int main(int argc, char **argv) {
	const char *bp = getenv("NVMTL_BUNDLE");
	if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u); if (b) CFBundleLoadExecutable(b); }
	cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
	cl_device_id dev; CK(cl_pick_intelxe(plat, &dev));
	cl_int err; cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CK(err);
	cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err); CK(err);
	const size_t n = 4096; unsigned init[4096], got[4096], part[100];
	for (size_t i = 0; i < n; i++) init[i] = (unsigned)i; for (int i = 0; i < 100; i++) part[i] = 5000u + (unsigned)i;
	const size_t offs[4] = { 0, 28, 256, 4 };
	for (int oi = 0; oi < 4; oi++) {
		cl_mem b = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, n * 4, init, &err); CK(err);
		CK(clEnqueueWriteBuffer(q, b, CL_TRUE, offs[oi], 400, part, 0, NULL, NULL));
		CK(clEnqueueReadBuffer(q, b, CL_TRUE, 0, n * 4, got, 0, NULL, NULL));
		int bad = 0; for (size_t i = 0; i < n; i++) { unsigned w = (i >= offs[oi] / 4 && i < offs[oi] / 4 + 100) ? 5000u + (unsigned)(i - offs[oi] / 4) : (unsigned)i; bad += got[i] != w; }
		printf("offset %3zu: %d wrong (word %zu = %u)\n", offs[oi], bad, offs[oi] / 4, got[offs[oi] / 4]); fails += bad != 0;
		clReleaseMemObject(b);
	}
	// GPU-side copies: dst offset 28 from src 0, and src offset 28 to dst 0
	for (int v = 0; v < 2; v++) {
		cl_mem a = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, n * 4, init, &err); CK(err);
		unsigned pat[4096]; for (size_t i = 0; i < n; i++) pat[i] = 9000u + (unsigned)i;
		cl_mem s2 = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, n * 4, pat, &err); CK(err);
		CK(clEnqueueCopyBuffer(q, s2, a, v ? 28 : 0, v ? 0 : 28, 400, 0, NULL, NULL));
		CK(clEnqueueReadBuffer(q, a, CL_TRUE, 0, n * 4, got, 0, NULL, NULL));
		const size_t d = v ? 0 : 7, so = v ? 7 : 0; int bad = 0;
		for (size_t i = 0; i < n; i++) { unsigned w = (i >= d && i < d + 100) ? 9000u + (unsigned)(i - d + so) : (unsigned)i; bad += got[i] != w; }
		printf("copy %s: %d wrong (word %zu = %u)\n", v ? "src+28 -> dst+0" : "src+0 -> dst+28", bad, d, got[d]); fails += bad != 0;
	}
	printf("%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
	return fails != 0;
}
