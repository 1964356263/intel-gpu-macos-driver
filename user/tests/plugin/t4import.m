// SPDX-License-Identifier: MIT
// t4import: a reader's import of a Tile4 VRAM backing, as WindowServer does it, in this process with a staged plugin.
//   NVMTL_BUNDLE=<bundle> NVMTL_LOG_PATH=<log> ./t4import [W H]
// 1. an IOSurface W x H BGRA (default 1280x720, bytesPerRow W*4) with a known pattern in its pages
// 2. IntelXe.kext SURFACE_VRAM2 CREATE: a Tile4 backing (pitch = align128(W*4), the layout Mesa's WSI renders with); its first
//    page-on tiles the pattern into it (or the backing is read as it is: both views below see the same bytes)
// 3. the plugin wraps the surface as a READER (MTLTextureUsageShaderRead): its import learns Tile4 and must alias it
//    (log: "Tile4 backing imported at ..." and "-> the family's VRAM"), not fall back to a private image
// 4. the GPU reads the texture through that alias (blit into a buffer) and the CPU reads the pages after a CPU lock (the
//    kernel's Tile4 -> linear page-off): the two must be byte-identical
// Prints PASS/FAIL. Build: clang -arch x86_64 -fobjc-arc -I<b580-tile4>/uapi ...
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurface.h>
#import <objc/message.h>
#include <errno.h>
#include "xe_drm.h"
#include "intelxe_drm.h"

static io_connect_t conn;
static int xioctl(unsigned long req, void *arg) {
    uint64_t in[2] = { req, (uint64_t)(uintptr_t)arg }, out = 0; uint32_t n = 1;
    if (IOConnectCallScalarMethod(conn, 0, in, 2, &out, &n)) { errno = ENXIO; return -1; }
    errno = (int)out; return out ? -1 : 0;
}
static id<MTLDevice> bundleDevice(const char *path) {
    NSBundle *b = [NSBundle bundleWithPath:@(path)]; NSError *e = nil;
    if (![b loadAndReturnError:&e]) { printf("bundle %s: %s\n", path, e.localizedDescription.UTF8String); return nil; }
    Class cls = [b classNamed:@"NVMTLDevice"]; if (!cls) return nil;
    io_iterator_t it = 0; id<MTLDevice> dev = nil;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return nil;
    for (io_service_t svc; !dev && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
        CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
        if (name && CFEqual(name, CFSTR("NVMTLDevice")))
            dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
        if (name) CFRelease(name);
    }
    IOObjectRelease(it);
    return dev;
}
static uint64_t fnv(const uint8_t *p, size_t n, uint64_t h) { for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; } return h; }
int main(int argc, char **argv) { @autoreleasepool {
    const uint32_t W = argc > 2 ? (uint32_t)atoi(argv[1]) : 1280, H = argc > 2 ? (uint32_t)atoi(argv[2]) : 720;
    const char *bp = getenv("NVMTL_BUNDLE");
    if (!bp) { printf("FAIL: NVMTL_BUNDLE not set\n"); return 2; }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelXe"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn)) { printf("FAIL: no IntelXe service\n"); return 2; }
    struct drm_get_cap cap = { .capability = INTELXE_CAP_SURFACE_VRAM_LAYOUT };
    int capok = xioctl(DRM_IOCTL_GET_CAP, &cap) == 0;
    printf("INTELXE_CAP_SURFACE_VRAM_LAYOUT: %s %llu\n", capok ? "ok" : "ioctl failed", (unsigned long long)cap.value);
    const size_t bpr = (size_t)W * 4;
    NSDictionary *props = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4,
                             (id)kIOSurfaceBytesPerRow: @(bpr), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!s || IOSurfaceGetBytesPerRow(s) != bpr) { printf("FAIL: IOSurfaceCreate (row %zu)\n", s ? IOSurfaceGetBytesPerRow(s) : 0); return 2; }
    IOSurfaceLock(s, 0, NULL);
    uint8_t *px = IOSurfaceGetBaseAddress(s);
    for (uint32_t y = 0; y < H; y++) for (uint32_t x = 0; x < W; x++) {
        uint8_t *p = px + y * bpr + x * 4; p[0] = (uint8_t)(x * 7 + y); p[1] = (uint8_t)(y * 3); p[2] = (uint8_t)(x ^ y); p[3] = 255; }
    IOSurfaceUnlock(s, 0, NULL);
    const uint32_t pitch = (uint32_t)((bpr + 127) & ~(size_t)127), rows32 = (H + 31) & ~31u;
    struct drm_intelxe_surface_vram2 v = { .surface_id = IOSurfaceGetID(s), .plane = 0, .size = (uint64_t)pitch * rows32,
                                        .flags = INTELXE_SURFACE_VRAM_CREATE, .modifier = I915_FORMAT_MOD_4_TILED, .pitch = pitch,
                                        .cpp = 4, .width = W, .height = H, .linear_pitch = (uint32_t)bpr };
    if (xioctl(DRM_IOCTL_INTELXE_SURFACE_VRAM2, &v)) { printf("FAIL: SURFACE_VRAM2 CREATE errno %d\n", errno); return 2; }
    printf("Tile4 backing: surface %u %ux%u pitch %u, %llu B (linear need %zu), gen %u, modifier 0x%llx\n", IOSurfaceGetID(s), W, H, v.pitch,
           (unsigned long long)v.size_out, bpr * H, v.gen, (unsigned long long)v.modifier);
    id<MTLDevice> dev = bundleDevice(bp);
    if (!dev) { printf("FAIL: no device from %s\n", bp); return 2; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d iosurface:s plane:0];
    if (!t) { printf("FAIL: newTextureWithDescriptor:iosurface: nil\n"); return 2; }
    // the GPU's view: blit the texture (through whatever the plugin built) into a linear buffer
    id<MTLBuffer> out = [dev newBufferWithLength:bpr * H options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    [be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
               toBuffer:out destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:bpr * H];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("FAIL: blit status %ld\n", (long)cb.status); return 2; }
    // the CPU's view: a lock pages the backing off (Tile4 -> linear on the copy engine)
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *cpu = IOSurfaceGetBaseAddress(s);
    uint64_t hg = 1469598103934665603ull, hc = hg; size_t diff = 0, first = (size_t)-1;
    for (uint32_t y = 0; y < H; y++) {
        const uint8_t *a = (const uint8_t *)out.contents + y * bpr, *b = cpu + y * bpr;
        hg = fnv(a, bpr, hg); hc = fnv(b, bpr, hc);
        for (size_t i = 0; i < bpr; i++) if (a[i] != b[i]) { if (first == (size_t)-1) first = y * bpr + i; diff++; }
    }
    // and the pattern written in step 1 (the backing's first page-on tiled it in, if the kernel does that at CREATE)
    size_t pat = 0;
    for (uint32_t y = 0; y < H; y++) for (uint32_t x = 0; x < W; x++) {
        const uint8_t *p = cpu + y * bpr + x * 4;
        if (p[0] != (uint8_t)(x * 7 + y) || p[1] != (uint8_t)(y * 3) || p[2] != (uint8_t)(x ^ y) || p[3] != 255) pat++; }
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    printf("GPU view %016llx, CPU view %016llx: %zu bytes differ (first at %zd); CPU view vs the pattern: %zu texels differ\n",
           (unsigned long long)hg, (unsigned long long)hc, diff, first == (size_t)-1 ? (ssize_t)-1 : (ssize_t)first, pat);
    printf("%s\n", diff == 0 ? "PASS: the GPU reads the Tile4 backing as the CPU sees it" : "FAIL: GPU and CPU views differ");
    CFRelease(s);
    IOServiceClose(conn);
    return diff ? 1 : 0;
} }
