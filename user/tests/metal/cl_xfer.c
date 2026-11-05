// SPDX-License-Identifier: MIT
// cl_xfer: steady-state blocking clEnqueueWriteBuffer / clEnqueueReadBuffer / clEnqueueMapBuffer cost by size on the B580
// (Apple's CL over our Metal plugin). Measurement only.
//   clang -arch x86_64 -mmacosx-version-min=15.0 -O2 -Wno-deprecated-declarations -o cl_xfer cl_xfer.c -framework OpenCL
#include <OpenCL/opencl.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static mach_timebase_info_data_t tb;
static double now_us(void) { return (double)mach_absolute_time() * tb.numer / tb.denom / 1e3; }
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d\n", #x, e_); exit(1); } } while (0)
int main(void) {
	mach_timebase_info(&tb);
	cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
	cl_device_id dev; CK(clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 1, &dev, NULL));
	cl_int err;
	cl_context ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err); CK(err);
	cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err); CK(err);
	size_t sizes[] = {64, 4096, 65536, 1 << 20, 16 << 20};
	void *host; posix_memalign(&host, 4096, 16 << 20); memset(host, 3, 16 << 20);
	for (int si = 0; si < 5; si++) {
		size_t S = sizes[si]; int N = S >= (1 << 20) ? 20 : 200;
		cl_mem b = clCreateBuffer(ctx, CL_MEM_READ_WRITE, S, NULL, &err); CK(err);
		double w[200], r[200], m[200];
		for (int i = 0; i < N + 3; i++) {
			double t = now_us(); CK(clEnqueueWriteBuffer(q, b, CL_TRUE, 0, S, host, 0, NULL, NULL)); double a = now_us() - t;
			t = now_us(); CK(clEnqueueReadBuffer(q, b, CL_TRUE, 0, S, host, 0, NULL, NULL)); double c = now_us() - t;
			t = now_us(); void *p = clEnqueueMapBuffer(q, b, CL_TRUE, CL_MAP_READ | CL_MAP_WRITE, 0, S, 0, NULL, NULL, &err); CK(err);
			((volatile char *)p)[0] = 1; CK(clEnqueueUnmapMemObject(q, b, p, 0, NULL, NULL)); CK(clFinish(q)); double d = now_us() - t;
			if (i >= 3) { w[i - 3] = a; r[i - 3] = c; m[i - 3] = d; }
		}
		qsort(w, N, 8, dcmp); qsort(r, N, 8, dcmp); qsort(m, N, 8, dcmp);
		printf("%8zu B: write p50 %7.1f us (%6.2f GB/s) | read p50 %7.1f us (%6.2f GB/s) | map+unmap+finish p50 %7.1f us\n",
		       S, w[N / 2], S / (w[N / 2] * 1e3), r[N / 2], S / (r[N / 2] * 1e3), m[N / 2]);
		clReleaseMemObject(b);
	}
	{   // 64 B out of a 64 MB buffer: does a small read move the whole buffer?
		size_t S = 64 << 20; cl_mem b = clCreateBuffer(ctx, CL_MEM_READ_WRITE, S, NULL, &err); CK(err);
		void *big; posix_memalign(&big, 4096, S); memset(big, 5, S);
		CK(clEnqueueWriteBuffer(q, b, CL_TRUE, 0, S, big, 0, NULL, NULL));
		double r[50], w[50];
		for (int i = 0; i < 53; i++) {
			double t = now_us(); CK(clEnqueueReadBuffer(q, b, CL_TRUE, 0, 64, host, 0, NULL, NULL)); double a = now_us() - t;
			t = now_us(); CK(clEnqueueWriteBuffer(q, b, CL_TRUE, 0, 64, host, 0, NULL, NULL)); double c = now_us() - t;
			if (i >= 3) { r[i - 3] = a; w[i - 3] = c; }
		}
		qsort(r, 50, 8, dcmp); qsort(w, 50, 8, dcmp);
		printf("64 B of a 64 MB buffer: read p50 %.1f us, write p50 %.1f us\n", r[25], w[25]);
	}
	return 0;
}
