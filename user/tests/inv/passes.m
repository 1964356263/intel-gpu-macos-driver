// SPDX-License-Identifier: MIT
// passes: what Apple GL's draw pattern costs on the GPU. A 2560x1302 BGRA8 + Depth32 target, N=500 small draws:
//   one   - one render encoder with all draws
//   rr    - a render encoder per draw (load/store)
//   rcr   - a render encoder per draw with a tiny compute dispatch between (GL's fixIndexBuffer), the draw indexed by its output
// GPU time from the command buffer's GPUStartTime/GPUEndTime, best of 5.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
static const char *src =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint vid [[vertex_id]], constant float2 &o [[buffer(0)]]) { float2 q[3] = { float2(0,0), float2(0.02,0), float2(0,0.02) };"
    " V v; v.p = float4(q[vid % 3] + o, 0.5, 1); return v; }\n"
    "fragment half4 fs() { return half4(1, 0.5, 0.25, 1); }\n"
    "kernel void fix(device ushort *ix [[buffer(0)]], uint i [[thread_position_in_grid]]) { ix[i] = (ushort)i; }\n";
int main(int argc, char **argv) { @autoreleasepool {
    const char *bp = getenv("NVMTL_BUNDLE");
    if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u);
              printf("preload %s: %s\n", bp, b && CFBundleLoadExecutable(b) ? "loaded" : "FAILED"); }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:@(src) options:nil error:&e];
    if (!lib) { printf("lib: %s\n", e.description.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"vs"]; rd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; const int nodepth = getenv("NODEPTH") != NULL; if (!nodepth) rd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    id<MTLRenderPipelineState> rp = [dev newRenderPipelineStateWithDescriptor:rd error:&e]; if (!rp) { printf("rp: %s\n", e.description.UTF8String); return 1; }
    id<MTLComputePipelineState> cp = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fix"] error:&e];
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionLessEqual; dd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> ds = [dev newDepthStencilStateWithDescriptor:dd];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(getenv("PW") ? atoi(getenv("PW")) : 2560) height:(getenv("PH") ? atoi(getenv("PH")) : 1302) mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> col = [dev newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float; td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> dep = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> ix = [dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    const int N = argc > 1 ? atoi(argv[1]) : 500;
    const char *modes[3] = { "one", "rr", "rcr" };
    for (int m = 0; m < 3; m++) {
        double best = 1e9, wall = 0;
        for (int rep = 0; rep < 5; rep++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> re = nil;
            for (int i = 0; i < N; i++) {
                if (m == 2) { id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:cp]; [ce setBuffer:ix offset:0 atIndex:0];
                              [ce dispatchThreads:MTLSizeMake(3, 1, 1) threadsPerThreadgroup:MTLSizeMake(3, 1, 1)]; [ce endEncoding]; }
                if (!re || m != 0) {
                    MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor renderPassDescriptor];
                    pd.colorAttachments[0].texture = col; pd.colorAttachments[0].loadAction = (i == 0) ? MTLLoadActionClear : MTLLoadActionLoad;
                    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
                    if (!nodepth) pd.depthAttachment.texture = dep; pd.depthAttachment.loadAction = (i == 0) ? MTLLoadActionClear : MTLLoadActionLoad;
                    pd.depthAttachment.storeAction = MTLStoreActionStore; pd.depthAttachment.clearDepth = 1.0;
                    re = [cb renderCommandEncoderWithDescriptor:pd]; [re setRenderPipelineState:rp]; if (!nodepth) [re setDepthStencilState:ds];
                }
                float o[2] = { -1 + (i % 50) * 0.04f, -1 + (i / 50 % 50) * 0.04f };
                [re setVertexBytes:o length:sizeof o atIndex:0];
                if (m == 2) [re drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:3 indexType:MTLIndexTypeUInt16 indexBuffer:ix indexBufferOffset:0];
                else [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                if (m != 0) { [re endEncoding]; re = nil; }
            }
            if (re) [re endEncoding];
            const CFTimeInterval w0 = CACurrentMediaTime();
            [cb commit]; [cb waitUntilCompleted];
            const double w = (CACurrentMediaTime() - w0) * 1e3;
            const double g = (cb.GPUEndTime - cb.GPUStartTime) * 1e3; if (g > 0 && g < best) best = g; if (!wall || w < wall) wall = w;
        }
        printf("%-4s %d draws: GPU %.3f ms (%.1f us per draw), commit-to-completion %.3f ms\n", modes[m], N, best < 1e9 ? best : 0, best < 1e9 ? best * 1e3 / N : 0, wall);
    }
} return 0; }
