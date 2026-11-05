// SPDX-License-Identifier: MIT
// ppool: many small Private buffers (Minecraft's chunk meshes): creation cost, and that each keeps its own contents
// (filled by a blit, copied back to Shared and checked); then a buffer texture over a small Private buffer.
#import <Metal/Metal.h>
#include "pickdev.h"
#include <mach/mach_time.h>
static double now_us(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e3; }
int main(void) { @autoreleasepool {
    const char *bp = getenv("NVMTL_BUNDLE");
    if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u);
              printf("preload %s: %s\n", bp, b && CFBundleLoadExecutable(b) ? "loaded" : "FAILED"); }
    id<MTLDevice> dev = mtl_pick_intelxe(); id<MTLCommandQueue> q = [dev newCommandQueue];
    const int N = 1500; NSMutableArray *bufs = [NSMutableArray new]; size_t total = 0;
    double t0 = now_us();
    for (int i = 0; i < N; i++) { size_t len = 4096 + (size_t)(i * 7919 % 200) * 4096; total += len;
        [bufs addObject:[dev newBufferWithLength:len options:MTLResourceStorageModePrivate]]; }
    double t1 = now_us();
    printf("%d Private buffers (%.1f MB): %.1f us each\n", N, total / 1048576.0, (t1 - t0) / N);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    for (int i = 0; i < N; i++) { id<MTLBuffer> b = bufs[i]; [be fillBuffer:b range:NSMakeRange(0, b.length) value:(uint8_t)(i * 37 + 1)]; }
    id<MTLBuffer> out = [dev newBufferWithLength:(NSUInteger)N * 8 options:MTLResourceStorageModeShared];
    for (int i = 0; i < N; i++) { id<MTLBuffer> b = bufs[i];
        [be copyFromBuffer:b sourceOffset:0 toBuffer:out destinationOffset:(NSUInteger)i * 8 size:4];
        [be copyFromBuffer:b sourceOffset:b.length - 4 toBuffer:out destinationOffset:(NSUInteger)i * 8 + 4 size:4]; }
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    int bad = 0; const uint8_t *o = out.contents;
    for (int i = 0; i < N; i++) for (int k = 0; k < 8; k++) bad += o[i * 8 + k] != (uint8_t)(i * 37 + 1);
    printf("contents: %d of %d bytes wrong\n", bad, N * 8);
    // a buffer texture over a small Private buffer, written by a blit from Shared, read back
    id<MTLBuffer> pb = [dev newBufferWithLength:64 * 256 options:MTLResourceStorageModePrivate];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [pb newTextureWithDescriptor:td offset:0 bytesPerRow:256];
    id<MTLBuffer> src = [dev newBufferWithLength:64 * 256 options:MTLResourceStorageModeShared];
    for (int i = 0; i < 64 * 256; i++) ((uint8_t *)src.contents)[i] = (uint8_t)(i * 13);
    id<MTLBuffer> rd = [dev newBufferWithLength:64 * 256 options:MTLResourceStorageModeShared];
    cb = [q commandBuffer]; be = [cb blitCommandEncoder];
    [be copyFromBuffer:src sourceOffset:0 toBuffer:pb destinationOffset:0 size:64 * 256];
    [be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(64, 64, 1) toBuffer:rd destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256 * 64];
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    bad = 0; for (int i = 0; i < 64 * 256; i++) bad += ((uint8_t *)rd.contents)[i] != (uint8_t)(i * 13);
    printf("buffer texture over a Private buffer: %s, %d of %d bytes wrong\n", t ? "made" : "NOT made", bad, 64 * 256);
    [bufs removeAllObjects];
} return 0; }
