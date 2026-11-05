// SPDX-License-Identifier: MIT
// clchurn: Geekbench-like OpenCL buffer churn on the plugin - buffers of mixed sizes and kinds (device, COPY_HOST_PTR,
// USE_HOST_PTR, ALLOC_HOST_PTR) created, used by a copy kernel, read back and released, with up to 48 kept alive at a
// time. Every 500 iterations it prints the plugin's VkDeviceMemory total (MTLDevice currentAllocatedSize, the same
// counter as the "holding MB" census) against the bytes the live buffers need; FAILS if the total exceeds live + 1.5 GB.
//   clchurn [iterations] [seconds]
#import <Metal/Metal.h>
#include <OpenCL/opencl.h>
#include "pickdev.h"
#include <mach/mach_time.h>
#define CK(x) do { cl_int e_ = (x); if (e_) { printf("%s -> %d (iteration %d)\n", #x, e_, it); return 1; } } while (0)
static double now_s(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9; }
static const char *src = "__kernel void cp(__global const uchar *a, __global uchar *b, uint n) { size_t i = get_global_id(0); if (i < n) b[i] = a[i] + 1; }\n";
typedef struct { cl_mem m; size_t n; void *host; } live_t;
int main(int argc, char **argv) { @autoreleasepool {
    int it = 0;
    const char *bp = getenv("NVMTL_BUNDLE");
    if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u);
              printf("preload %s: %s\n", bp, b && CFBundleLoadExecutable(b) ? "loaded" : "FAILED"); }
    id<MTLDevice> dev = mtl_pick_intelxe();
    const int iters = argc > 1 ? atoi(argv[1]) : 20000; const double secs = argc > 2 ? atof(argv[2]) : 1e9;
    cl_platform_id plat; CK(clGetPlatformIDs(1, &plat, NULL));
    cl_device_id cd; CK(cl_pick_intelxe(plat, &cd));
    cl_int err; cl_context ctx = clCreateContext(NULL, 1, &cd, NULL, NULL, &err); CK(err);
    cl_command_queue q = clCreateCommandQueue(ctx, cd, 0, &err); CK(err);
    cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &err); CK(err); CK(clBuildProgram(p, 1, &cd, "", NULL, NULL));
    cl_kernel k = clCreateKernel(p, "cp", &err); CK(err);
    live_t live[48]; memset(live, 0, sizeof live);
    static const size_t sizes[] = { 4096, 16384, 65536, 200000, 1u << 20, (1u << 20) + 4096, 3u << 20, 9u << 20, 24u << 20, 64u << 20 };
    unsigned seed = 12345; size_t peak = 0, worst_over = 0; const double t0 = now_s();
    uint8_t *scratch = malloc(64u << 20); memset(scratch, 7, 64u << 20);
    for (it = 0; it < iters && now_s() - t0 < secs; it++) {
        seed = seed * 1103515245u + 12345u; const size_t n = sizes[(seed >> 16) % 10];
        const int kind = (int)((seed >> 8) % 4);
        void *host = NULL; cl_mem_flags f = CL_MEM_READ_WRITE;
        if (kind == 1) f |= CL_MEM_COPY_HOST_PTR;
        if (kind == 2) { posix_memalign(&host, 16384, (n + 16383) & ~(size_t)16383); memset(host, 3, n); f |= CL_MEM_USE_HOST_PTR; }
        if (kind == 3) f |= CL_MEM_ALLOC_HOST_PTR;
        cl_mem a = clCreateBuffer(ctx, f, n, kind == 1 ? scratch : host, &err); CK(err);
        cl_mem b = clCreateBuffer(ctx, CL_MEM_READ_WRITE, n, NULL, &err); CK(err);
        cl_uint nn = (cl_uint)n; CK(clSetKernelArg(k, 0, sizeof a, &a)); CK(clSetKernelArg(k, 1, sizeof b, &b)); CK(clSetKernelArg(k, 2, sizeof nn, &nn));
        size_t g = (n + 255) / 256 * 256, l = 256; CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &l, 0, NULL, NULL));
        if (it % 8 == 0) { uint8_t r[16]; CK(clEnqueueReadBuffer(q, b, CL_TRUE, n - 16, 16, r, 0, NULL, NULL)); }
        clReleaseMemObject(a);
        // keep b alive in a random slot; the one it displaces is released
        const int s = (int)((seed >> 4) % 48);
        if (live[s].m) { clReleaseMemObject(live[s].m); free(live[s].host); }
        live[s] = (live_t){ b, n, host };
        const int every = getenv("CHURN_EVERY") ? atoi(getenv("CHURN_EVERY")) : 500;
        if (it % every == every - 1) {
            CK(clFinish(q));
            size_t need = 0; for (int i = 0; i < 48; i++) if (live[i].m) need += live[i].n;
            const size_t held = (size_t)dev.currentAllocatedSize; if (held > peak) peak = held;
            const size_t over = held > need ? held - need : 0; if (over > worst_over) worst_over = over;
            printf("iteration %d: holding %zu MB of VkDeviceMemory, live buffers need %zu MB, over by %zu MB\n", it + 1, held >> 20, need >> 20, over >> 20);
            fflush(stdout);
        }
    }
    CK(clFinish(q));
    for (int i = 0; i < 48; i++) if (live[i].m) { clReleaseMemObject(live[i].m); free(live[i].host); }
    clFinish(q);
    const size_t end = (size_t)dev.currentAllocatedSize;
    const int ok = worst_over < ((size_t)1536 << 20);
    printf("%s: %d iterations in %.0f s, peak %zu MB held, worst %zu MB over the live buffers, %zu MB held after release\n",
           ok ? "PASSED" : "FAILED", it, now_s() - t0, peak >> 20, worst_over >> 20, end >> 20);
    return ok ? 0 : 1;
} }
