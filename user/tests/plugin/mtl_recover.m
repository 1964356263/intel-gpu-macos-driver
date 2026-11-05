// SPDX-License-Identifier: MIT
// mtl_recover: in-process test of the Metal plugin's GPU reset recovery (plugin.recover, Mesa nvmtl_anv_device_recover_v1).
// Loads a STAGED plugin build (NVMTL_BUNDLE, required: never the installed one, never WindowServer) and checks that after a
// lost device the in-flight command buffers end with an error (their handlers run) and the same MTLDevice keeps working:
// the same buffers (same contents pointer and gpuAddress), textures and pipelines, new allocations, new command buffers.
//
//   mtl_recover --fake      the 3rd next completed fence wait is reported lost (nvmtl_vk_fake_lost_arm); the queue is
//                           replaced for real (FORCE). Needs no hang.
//   mtl_recover --fsubmit   the 3rd next vkQueueSubmit is reported lost: recovered, then submitted again.
//   mtl_recover --hang      a REAL hang of this process's own queue: a compute kernel that spins until a flag it never
//                           sees; IntelXe.kext's watchdog / GuC reset bans the queue (~10.5 s), anv reports
//                           VK_ERROR_DEVICE_LOST; nothing else on the GPU is touched. --victims N commits N more command
//                           buffers behind it.
//   --rounds R              repeat loss + check R times (the plugin allows 3 recoveries a minute)
// Exit: 0 pass, 1 fail, 2 setup error. Prints the plugin's recovery counters (nvmtl_vk_recover_counts) when exported.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdatomic.h>

static double now_s(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
static double T0;

static id<MTLDevice> bundleDevice(const char *path) {
    NSBundle *b = [NSBundle bundleWithPath:@(path)];
    NSError *e = nil;
    if (![b loadAndReturnError:&e]) { printf("bundle %s: %s\n", path, e.localizedDescription.UTF8String); return nil; }
    Class cls = [b classNamed:@"NVMTLDevice"];
    if (!cls) { printf("bundle %s has no NVMTLDevice\n", path); return nil; }
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return nil;
    id<MTLDevice> dev = nil;
    for (io_service_t svc; !dev && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
        CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
        if (name && CFEqual(name, CFSTR("NVMTLDevice")))
            dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
        if (name) CFRelease(name);
    }
    IOObjectRelease(it);
    return dev;
}

static NSString *const kSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void fill(device uint *o [[buffer(0)]], constant uint &v [[buffer(1)]], uint i [[thread_position_in_grid]]) { o[i] = v + i; }\n"
"kernel void spin(device atomic_uint *flag [[buffer(0)]], device uint *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
"    uint n = 0;\n"
"    while (atomic_load_explicit(flag, memory_order_relaxed) == 0u) { n++; if (n == 0xffffffffu) atomic_store_explicit((device atomic_uint *)out, n, memory_order_relaxed); }\n"
"    out[1] = n;\n"
"}\n";

static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLComputePipelineState> psFill, psSpin;
static id<MTLBuffer> bufA, flagBuf, spinOut, readback; static id<MTLTexture> tex;
static void *aContents; static uint64_t aGpu;
enum { N = 4096 };
static int fails;
#define CHECK(c, ...) do { if (c) printf("  ok   " __VA_ARGS__); else { printf("  FAIL " __VA_ARGS__); fails++; } printf("\n"); } while (0)

static id<MTLCommandBuffer> fillCB(id<MTLBuffer> b, uint32_t v) {
    id<MTLCommandBuffer> cb = [q commandBuffer];
    if (!cb) return nil;
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:psFill]; [e setBuffer:b offset:0 atIndex:0]; [e setBytes:&v length:4 atIndex:1];
    [e dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [e endEncoding];
    return cb;
}
static int verifyFill(id<MTLBuffer> b, uint32_t v) {
    const uint32_t *p = b.contents;
    for (uint32_t i = 0; i < N; i++) if (p[i] != v + i) { printf("    word %u = %u, want %u\n", i, p[i], v + i); return 0; }
    return 1;
}
static const char *st(MTLCommandBufferStatus s) {
    switch (s) { case MTLCommandBufferStatusCompleted: return "Completed"; case MTLCommandBufferStatusError: return "Error";
    case MTLCommandBufferStatusCommitted: return "Committed"; case MTLCommandBufferStatusScheduled: return "Scheduled"; default: return "other"; }
}
static void counters(const char *when) {
    int (*fn)(unsigned *, unsigned *, unsigned long long *, unsigned long long *) = dlsym(RTLD_DEFAULT, "nvmtl_vk_recover_counts");
    if (!fn) { printf("  [%s] nvmtl_vk_recover_counts not exported\n", when); return; }
    unsigned rec = 0, gen = 0; unsigned long long h = 0, v = 0;
    int up = fn(&rec, &gen, &h, &v);
    printf("  [%s] plugin: backend %s, recoveries %u, generation %u, command buffers lost: hang %llu, victim %llu\n", when, up ? "DOWN" : "up", rec, gen, h, v);
}

// everything made before the loss still works, and new things work
static void checkAlive(int round, uint32_t v) {
    printf("after loss %d:\n", round);
    CHECK(bufA.contents == aContents && bufA.gpuAddress == aGpu, "buffer A keeps its contents pointer %p and gpuAddress 0x%llx", bufA.contents, (unsigned long long)bufA.gpuAddress);
    id<MTLCommandBuffer> cb = fillCB(bufA, v);
    CHECK(cb != nil, "a new command buffer from the same queue");
    if (!cb) return;
    [cb commit]; [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted && verifyFill(bufA, v), "fill of the old buffer with the old pipeline: %s, data %s",
          st(cb.status), verifyFill(bufA, v) ? "right" : "WRONG");
    // the pre-loss texture: blit it into a buffer and compare with what was uploaded
    memset(readback.contents, 0, 64 * 64 * 4);
    id<MTLCommandBuffer> bc = [q commandBuffer];
    id<MTLBlitCommandEncoder> be = [bc blitCommandEncoder];
    [be copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(64, 64, 1)
               toBuffer:readback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256 * 64];
    [be endEncoding]; [bc commit]; [bc waitUntilCompleted];
    const uint32_t *px = readback.contents; int good = 1;
    for (int i = 0; i < 64 * 64; i++) if (px[i] != (0xff000000u | (uint32_t)i * 2654435761u >> 8)) { good = 0; break; }
    CHECK(bc.status == MTLCommandBufferStatusCompleted && good, "blit of the pre-loss texture: %s, texels %s", st(bc.status), good ? "intact" : "DIFFER");
    id<MTLBuffer> fresh = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> c2 = fresh ? fillCB(fresh, v + 7) : nil;
    [c2 commit]; [c2 waitUntilCompleted];
    CHECK(fresh && c2.status == MTLCommandBufferStatusCompleted && verifyFill(fresh, v + 7), "a new buffer and a new command queue's work");
    id<MTLCommandQueue> q2 = [dev newCommandQueue];
    id<MTLCommandBuffer> c3 = [q2 commandBuffer];
    [c3 commit]; [c3 waitUntilCompleted];
    CHECK(q2 && c3.status == MTLCommandBufferStatusCompleted, "a new command queue");
}

int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    int fake = 0, fsubmit = 0, hang = 0, victims = 3, rounds = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--fake")) fake = 1;
        else if (!strcmp(argv[i], "--fsubmit")) fsubmit = 1;
        else if (!strcmp(argv[i], "--hang")) hang = 1;
        else if (!strcmp(argv[i], "--victims") && i + 1 < argc) victims = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rounds") && i + 1 < argc) rounds = atoi(argv[++i]);
        else { printf("usage: mtl_recover --fake|--fsubmit|--hang [--victims N] [--rounds R]\n"); return 2; }
    }
    if (fake + fsubmit + hang != 1) { printf("pick one of --fake, --fsubmit, --hang\n"); return 2; }
    const char *bundle = getenv("NVMTL_BUNDLE");
    if (!bundle) { printf("NVMTL_BUNDLE (a staged plugin build) is required\n"); return 2; }
    T0 = now_s();
    dev = bundleDevice(bundle);
    if (!dev) { printf("no device from %s\n", bundle); return 2; }
    printf("device: %s (%s) bundle %s, Vulkan driver %s\n", dev.name.UTF8String, NSStringFromClass([dev class]).UTF8String, bundle,
           getenv("NVMTL_ICD_LIB") ?: "(installed)");
    q = [dev newCommandQueue];
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSource options:nil error:&e];
    if (!lib) { printf("library: %s\n", e.localizedDescription.UTF8String); return 2; }
    psFill = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fill"] error:&e];
    psSpin = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"spin"] error:&e];
    if (!q || !psFill || !psSpin) { printf("queue/pipelines: %s\n", e.localizedDescription.UTF8String ?: "nil"); return 2; }
    bufA = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
    flagBuf = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    spinOut = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    readback = [dev newBufferWithLength:64 * 64 * 4 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderRead;
    tex = [dev newTextureWithDescriptor:td];
    uint32_t *texels = malloc(64 * 64 * 4);
    for (int i = 0; i < 64 * 64; i++) texels[i] = 0xff000000u | (uint32_t)i * 2654435761u >> 8;
    id<MTLBuffer> up = [dev newBufferWithBytes:texels length:64 * 64 * 4 options:MTLResourceStorageModeShared];
    free(texels);
    id<MTLCommandBuffer> uc = [q commandBuffer]; id<MTLBlitCommandEncoder> ue = [uc blitCommandEncoder];
    [ue copyFromBuffer:up sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:256 * 64 sourceSize:MTLSizeMake(64, 64, 1)
             toTexture:tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [ue endEncoding]; [uc commit]; [uc waitUntilCompleted];
    aContents = bufA.contents; aGpu = bufA.gpuAddress;
    id<MTLCommandBuffer> c0 = fillCB(bufA, 1000); [c0 commit]; [c0 waitUntilCompleted];
    printf("before:\n");
    CHECK(uc.status == MTLCommandBufferStatusCompleted && c0.status == MTLCommandBufferStatusCompleted && verifyFill(bufA, 1000), "baseline fill and texture upload");
    counters("before");
    if (fails) return 1;

    for (int round = 1; round <= rounds; round++) {
        printf("loss %d (%s) at %.1f s:\n", round, fake ? "faked fence wait" : fsubmit ? "faked submit" : "REAL HANG", now_s() - T0);
        __block _Atomic int handlers = 0;
        if (hang) {
            *(volatile uint32_t *)flagBuf.contents = 0;
            id<MTLCommandBuffer> h = [q commandBuffer];
            id<MTLComputeCommandEncoder> he = [h computeCommandEncoder];
            [he setComputePipelineState:psSpin]; [he setBuffer:flagBuf offset:0 atIndex:0]; [he setBuffer:spinOut offset:0 atIndex:1];
            [he dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [he endEncoding];
            [h addCompletedHandler:^(id<MTLCommandBuffer> b) { atomic_fetch_add(&handlers, 1); }];
            [h commit];
            NSMutableArray *vs = [NSMutableArray new];
            for (int k = 0; k < victims; k++) {
                id<MTLBuffer> vb = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> v = fillCB(vb, 5000 + k);
                [v addCompletedHandler:^(id<MTLCommandBuffer> b) { atomic_fetch_add(&handlers, 1); }];
                [v commit]; [vs addObject:@[v, vb]];
            }
            const double t = now_s();
            while (h.status < MTLCommandBufferStatusCompleted && now_s() - t < 35) usleep(20000);
            if (h.status < MTLCommandBufferStatusCompleted) {
                printf("  FAIL the hang did not end in 35 s - writing the stop flag (rescue)\n"); fails++;
                *(volatile uint32_t *)flagBuf.contents = 1;
                [h waitUntilCompleted];
            }
            printf("  hang command buffer: %s after %.1f s, error %s\n", st(h.status), now_s() - t,
                   h.error ? [NSString stringWithFormat:@"%@ %ld \"%@\"", h.error.domain, (long)h.error.code, h.error.localizedDescription].UTF8String : "none");
            CHECK(h.status == MTLCommandBufferStatusError, "the hanging command buffer ended with an error");
            int vErr = 0, vOk = 0;
            for (NSArray *p in vs) { id<MTLCommandBuffer> v = p[0]; [v waitUntilCompleted];
                if (v.status == MTLCommandBufferStatusError) vErr++;
                else if (v.status == MTLCommandBufferStatusCompleted && verifyFill(p[1], 5000 + (int)[vs indexOfObject:p])) vOk++;
                if (v.error) printf("    victim: %s %ld \"%s\"\n", v.error.domain.UTF8String, (long)v.error.code, v.error.localizedDescription.UTF8String); }
            printf("  victims: %d ended with an error, %d ran after the recovery with the right data\n", vErr, vOk);
            CHECK(vErr + vOk == victims, "every command buffer behind the hang finished (error or completed)");
            usleep(100000);
            CHECK(handlers == victims + 1, "all %d completion handlers ran (%d)", victims + 1, (int)handlers);
        } else {
            void (*arm)(int, unsigned long long) = dlsym(RTLD_DEFAULT, "nvmtl_vk_fake_lost_arm");
            if (!arm) { printf("  FAIL the plugin has no nvmtl_vk_fake_lost_arm\n"); return 1; }
            arm(fsubmit, 3);
            int nErr = 0, nOk = 0; NSError *first = nil;
            for (int k = 0; k < 12; k++) {
                id<MTLCommandBuffer> c = fillCB(bufA, 2000 + 10 * k);
                if (!c) { printf("  FAIL commandBuffer returned nil at %d\n", k); fails++; break; }
                [c addCompletedHandler:^(id<MTLCommandBuffer> b) { atomic_fetch_add(&handlers, 1); }];
                [c commit]; [c waitUntilCompleted];
                if (c.status == MTLCommandBufferStatusError) { nErr++; if (!first) first = c.error; }
                else if (c.status == MTLCommandBufferStatusCompleted && verifyFill(bufA, 2000 + 10 * k)) nOk++;
            }
            printf("  12 command buffers: %d errors (%s), %d completed with the right data\n", nErr,
                   first ? [NSString stringWithFormat:@"%ld \"%@\"", (long)first.code, first.localizedDescription].UTF8String : "-", nOk);
            if (fake) CHECK(nErr == 1 && nOk == 11, "exactly the faked one failed");
            else CHECK(nErr == 0 && nOk == 12, "the faked submit was recovered and submitted again");
            usleep(100000);
            CHECK(handlers == 12, "all completion handlers ran (%d)", (int)handlers);
        }
        counters("after loss");
        checkAlive(round, 3000 + round);
    }
    printf("%s: %d failure(s) in %.1f s\n", fails ? "FAILED" : "PASSED", fails, now_s() - T0);
    return fails ? 1 : 0;
} }
