// SPDX-License-Identifier: MIT
// memprobe: is the plugin's host-visible memory cached? read/write bandwidth of an MTLBuffer's contents vs malloc, and the cost
// of one locked instruction right after writing 2 KiB there (a store-buffer / write-combining drain).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
static double now_ns(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom; }
static volatile uint64_t sink; static uint64_t ctr;
static void probe(const char *what, uint8_t *p, size_t n) {
    double t0 = now_ns(); memset(p, 1, n); double t1 = now_ns();
    uint64_t s = 0; for (size_t i = 0; i < n; i += 8) s += *(volatile uint64_t *)(p + i); sink = s; double t2 = now_ns();
    // 20000 x (write 2 KiB at a moving offset, then one atomic add): ns per round, and without the atomic
    double t3 = now_ns(); size_t off = 0;
    for (int k = 0; k < 20000; k++) { memset(p + off, k, 2048); __atomic_fetch_add(&ctr, 1, __ATOMIC_SEQ_CST); off = (off + 2048) % (n - 2048); }
    double t4 = now_ns(); off = 0;
    for (int k = 0; k < 20000; k++) { memset(p + off, k, 2048); sink += k; off = (off + 2048) % (n - 2048); }
    double t5 = now_ns();
    printf("%-22s write %6.2f GB/s  read %6.2f GB/s | 2KiB+atomic %6.0f ns  2KiB alone %6.0f ns\n", what, n / (t1 - t0), n / (t2 - t1),
           (t4 - t3) / 20000, (t5 - t4) / 20000);
}
typedef id<MTLDevice> (*mkdev)(void);
int main(int argc, char **argv) { @autoreleasepool {
    const size_t N = 16 << 20;
    uint8_t *m = malloc(N); probe("malloc", m, N);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    printf("device %s (%s)\n", dev.name.UTF8String, NSStringFromClass([dev class]).UTF8String);
    id<MTLBuffer> b = [dev newBufferWithLength:N options:MTLResourceStorageModeShared]; probe("MTLBuffer shared", b.contents, N);
    id<MTLBuffer> w = [dev newBufferWithLength:N options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined]; probe("MTLBuffer shared WC", w.contents, N);
    id<MTLBuffer> g = [dev newBufferWithLength:N options:MTLResourceStorageModeManaged]; probe("MTLBuffer managed", g.contents, N);
    id<MTLBuffer> s = [dev newBufferWithLength:64 << 10 options:MTLResourceStorageModeShared]; probe("MTLBuffer shared 64K", s.contents, 64 << 10);
} return 0; }
