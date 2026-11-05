// SPDX-License-Identifier: MIT
// clpwb: byte-offset OpenCL writes and copies (offsets 1, 2, 3, 5): do they land, and does the plugin need the twin
#include <OpenCL/opencl.h>
#include "pickdev.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d\n", #x, e_); return 1; } } while (0)
int main(void) {
	const char *bp = getenv("NVMTL_BUNDLE");
	if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u); if (b) CFBundleLoadExecutable(b); }
	cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
	cl_device_id dev; CK(cl_pick_intelxe(plat, &dev));
	cl_int err; cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CK(err);
	cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err); CK(err);
	const size_t n = 16384; unsigned char init[16384], got[16384], part[333];
	for (size_t i = 0; i < n; i++) init[i] = (unsigned char)i; for (int i = 0; i < 333; i++) part[i] = (unsigned char)(200 + i);
	static const size_t offs[4] = { 1, 2, 3, 5 }; int fails = 0;
	for (int v = 0; v < 2; v++) for (int oi = 0; oi < 4; oi++) {
		const size_t o = offs[oi];
		cl_mem b = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, n, init, &err); CK(err);
		if (!v) CK(clEnqueueWriteBuffer(q, b, CL_TRUE, o, 333, part, 0, NULL, NULL));
		else { cl_mem s = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, 333, part, &err); CK(err);
		       CK(clEnqueueCopyBuffer(q, s, b, 0, o, 333, 0, NULL, NULL)); clFinish(q); clReleaseMemObject(s); }
		CK(clEnqueueReadBuffer(q, b, CL_TRUE, 0, n, got, 0, NULL, NULL));
		int bad = 0; for (size_t i = 0; i < n; i++) { unsigned char w = (i >= o && i < o + 333) ? (unsigned char)(200 + (i - o)) : (unsigned char)i; bad += got[i] != w; }
		printf("%s at byte offset %zu: %d wrong\n", v ? "copy" : "write", o, bad); fails += bad != 0;
		clReleaseMemObject(b);
	}
	printf("%s (%d failures)\n", fails ? "FAILED" : "PASSED", fails);
	return fails != 0;
}
