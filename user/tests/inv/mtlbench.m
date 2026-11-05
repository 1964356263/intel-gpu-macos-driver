// SPDX-License-Identifier: MIT
// mtlbench: Geekbench-Metal-like compute patterns, wall time per pattern (best of 3):
//   tex    100 dispatches of a 3x3 texture filter on a 3840x2160 RGBA8 image per command buffer (ping-pong), 5 CBs
//   buf    a 32 MB buffer kernel chain: 50 dispatches per CB, 5 CBs
//   small  2000 command buffers of one small dispatch, commit + wait each
//   churn  200 x (new 16 MB Private + Managed buffer, kernel, blit back, release)
//   tgv    1000 dispatches with 20 different threadgroup sizes (pipeline variants)
#import <Metal/Metal.h>
#include <mach/mach_time.h>
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6; }
static const char *src =
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void blur(texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::write> b [[texture(1)]], uint2 p [[thread_position_in_grid]]) {\n"
"  if (p.x >= a.get_width() || p.y >= a.get_height()) return; float4 s = 0; for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++)\n"
"  s += a.read(uint2(clamp(int(p.x) + dx, 0, int(a.get_width()) - 1), clamp(int(p.y) + dy, 0, int(a.get_height()) - 1))); b.write(s / 9.0, p); }\n"
"kernel void saxpy(device float *x [[buffer(0)]], device float *y [[buffer(1)]], uint i [[thread_position_in_grid]]) { y[i] = 1.0001f * x[i] + y[i]; }\n";
int main(int argc, char **argv) { @autoreleasepool {
    const char *bp = getenv("NVMTL_BUNDLE");
    if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u); if (b) CFBundleLoadExecutable(b); }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:@(src) options:nil error:&e]; if (!lib) { printf("%s\n", e.description.UTF8String); return 1; }
    id<MTLComputePipelineState> blur = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"blur"] error:&e];
    id<MTLComputePipelineState> saxpy = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"saxpy"] error:&e];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:3840 height:2160 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t0 = [dev newTextureWithDescriptor:td], t1 = [dev newTextureWithDescriptor:td];
    const size_t N = 8u << 20; id<MTLBuffer> x = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModePrivate], y = [dev newBufferWithLength:N * 4 options:MTLResourceStorageModePrivate];
    const char *only = argc > 1 ? argv[1] : NULL;
    for (int pat = 0; pat < 5; pat++) {
        static const char *nm[5] = { "tex", "buf", "small", "churn", "tgv" };
        if (only && strcmp(only, nm[pat])) continue;
        double best = 1e18;
        for (int rep = 0; rep < 3; rep++) {
            const double s = now_ms();
            if (pat == 0) for (int c = 0; c < 5; c++) { id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:blur];
                for (int i = 0; i < 100; i++) { [ce setTexture:(i & 1) ? t1 : t0 atIndex:0]; [ce setTexture:(i & 1) ? t0 : t1 atIndex:1]; [ce dispatchThreads:MTLSizeMake(3840, 2160, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; }
                [ce endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
            if (pat == 1) for (int c = 0; c < 5; c++) { id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:saxpy];
                [ce setBuffer:x offset:0 atIndex:0]; [ce setBuffer:y offset:0 atIndex:1];
                for (int i = 0; i < 50; i++) [ce dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                [ce endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
            if (pat == 2) for (int c = 0; c < 2000; c++) { id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:saxpy];
                [ce setBuffer:x offset:0 atIndex:0]; [ce setBuffer:y offset:0 atIndex:1]; [ce dispatchThreads:MTLSizeMake(4096, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                [ce endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
            if (pat == 3) for (int c = 0; c < 200; c++) { @autoreleasepool {
                id<MTLBuffer> a = [dev newBufferWithLength:16u << 20 options:MTLResourceStorageModePrivate], m = [dev newBufferWithLength:16u << 20 options:MTLResourceStorageModeManaged];
                id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:saxpy];
                [ce setBuffer:m offset:0 atIndex:0]; [ce setBuffer:a offset:0 atIndex:1]; [ce dispatchThreads:MTLSizeMake(4u << 20, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)]; [ce endEncoding];
                id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; [be copyFromBuffer:a sourceOffset:0 toBuffer:m destinationOffset:0 size:16u << 20]; [be synchronizeResource:m]; [be endEncoding];
                [cb commit]; [cb waitUntilCompleted]; } }
            if (pat == 4) { id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:saxpy];
                [ce setBuffer:x offset:0 atIndex:0]; [ce setBuffer:y offset:0 atIndex:1];
                for (int i = 0; i < 1000; i++) [ce dispatchThreads:MTLSizeMake(65536, 1, 1) threadsPerThreadgroup:MTLSizeMake(32 * (1 + i % 20), 1, 1)];
                [ce endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
            const double t = now_ms() - s; if (t < best) best = t;
        }
        printf("%-6s %9.2f ms\n", nm[pat], best);
    }
} return 0; }
