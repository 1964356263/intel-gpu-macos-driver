// SPDX-License-Identifier: MIT
// mtl_smoke: first Metal test on the Arc B580 (NMXAccel + NVMTLDriver.bundle + ANV over IntelXe.kext).
//
// Picks the B580's MTLDevice explicitly (never MTLCreateSystemDefaultDevice: that is the UHD 770 WindowServer runs on),
// compiles a compute kernel from source at runtime, writes 64 Ki uints into a shared buffer and checks every value.
//
//   NVMTL_ENABLE=1 ./mtl_smoke           (NVMTL_ENABLE passes the plugin's allow-list, NVMTLDevice.m:543)
//   ./mtl_smoke --list                   only list the Metal devices this process sees
//
// Exit: 0 pass, 1 no B580 device, 2 compile/pipeline failure, 3 GPU error, 4 wrong values.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>

static NSString *const kSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "kernel void fill(device uint *out [[buffer(0)]], constant uint &k [[buffer(1)]],\n"
     "                 uint gid [[thread_position_in_grid]]) {\n"
     "    out[gid] = gid * 3u + k;\n"
     "}\n";

// The registry ID of the NMXAccel accelerator (0 if none). An MTLIOAccelDevice reports its accelerator's ID.
static uint64_t nmx_registry_id(void)
{
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NMXAccel"));
    if (!s) return 0;
    uint64_t id = 0;
    IORegistryEntryGetRegistryEntryID(s, &id);
    IOObjectRelease(s);
    return id;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        const BOOL listOnly = argc > 1 && !strcmp(argv[1], "--list");
        const uint64_t nmx = nmx_registry_id();
        printf("NMXAccel registry id: 0x%llx%s\n", (unsigned long long)nmx, nmx ? "" : " (NMXAccel is not running)");

        NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
        id<MTLDevice> dev = nil;
        for (id<MTLDevice> d in all) {
            const BOOL ours = (nmx && d.registryID == nmx) || [NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"];
            printf("  %s  %-40s class %-24s registryID 0x%llx headless %d lowPower %d\n", ours ? "*" : " ",
                   d.name.UTF8String, NSStringFromClass([d class]).UTF8String, (unsigned long long)d.registryID,
                   d.isHeadless, d.isLowPower);
            if (ours && !dev) dev = d;
        }
        if (listOnly) return dev ? 0 : 1;
        if (!dev) { fprintf(stderr, "FAIL: no B580 Metal device among %lu\n", (unsigned long)all.count); return 1; }

        NSError *err = nil;
        MTLCompileOptions *opt = [MTLCompileOptions new];
        id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:opt error:&err];
        if (!lib) { fprintf(stderr, "FAIL: newLibraryWithSource: %s\n", err.localizedDescription.UTF8String); return 2; }
        id<MTLFunction> fn = [lib newFunctionWithName:@"fill"];
        if (!fn) { fprintf(stderr, "FAIL: no function 'fill' (library %s)\n", NSStringFromClass([lib class]).UTF8String); return 2; }
        id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:fn error:&err];
        if (!pso) { fprintf(stderr, "FAIL: pipeline: %s\n", err.localizedDescription.UTF8String); return 2; }

        const NSUInteger n = 65536;
        const uint32_t k = 0x1234;
        id<MTLBuffer> out = [dev newBufferWithLength:n * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (!out) { fprintf(stderr, "FAIL: newBufferWithLength\n"); return 3; }
        memset(out.contents, 0xA5, n * sizeof(uint32_t));

        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:out offset:0 atIndex:0];
        [enc setBytes:&k length:sizeof k atIndex:1];
        NSUInteger tg = MIN((NSUInteger)64, pso.maxTotalThreadsPerThreadgroup);
        [enc dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "FAIL: command buffer status %ld: %s\n", (long)cb.status, cb.error.localizedDescription.UTF8String);
            return 3;
        }

        const uint32_t *v = out.contents;
        NSUInteger bad = 0;
        for (NSUInteger i = 0; i < n; i++)
            if (v[i] != (uint32_t)i * 3u + k) { if (bad++ < 8) fprintf(stderr, "  [%lu] = 0x%08x, want 0x%08x\n", (unsigned long)i, v[i], (uint32_t)i * 3u + k); }
        printf("%s: %lu of %lu values wrong on %s (threadgroup %lu)\n", bad ? "FAIL" : "PASS", (unsigned long)bad,
               (unsigned long)n, dev.name.UTF8String, (unsigned long)tg);
        return bad ? 4 : 0;
    }
}
