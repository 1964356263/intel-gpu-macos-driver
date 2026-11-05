// SPDX-License-Identifier: MIT
// NVMTL_HITCH_MS smoke test: 40 Metal "frames" (a fake drawable presented by each command buffer), every 10th one
// stalls with buffer/texture churn, a compute pipeline made from source and a 30 ms sleep; then a few
// -[NSOpenGLContext flushBuffer] frames with one slow one. Run with NVMTL_HITCH_MS=20 and look for HITCH lines.
#import <Metal/Metal.h>
#import <AppKit/AppKit.h>
#include <unistd.h>

@interface FakeDrawable : NSObject <MTLDrawable>
@end
@implementation FakeDrawable
- (void)present {}
- (void)presentAtTime:(CFTimeInterval)t { (void)t; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)d { (void)d; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)b { (void)b; }
- (CFTimeInterval)presentedTime { return 0; }
- (NSUInteger)drawableID { return 1; }
@end

int main(int argc, char **argv)
{
    @autoreleasepool {
        // NVMTL_BUNDLE: preload that plugin build so its classes are the ones Metal instantiates (a test hook, as in cltr)
        const char *bp = getenv("NVMTL_BUNDLE");
        if (bp) { CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bp, strlen(bp), true); CFBundleRef b = CFBundleCreate(NULL, u);
                  printf("preload %s: %s\n", bp, b && CFBundleLoadExecutable(b) ? "loaded" : "FAILED"); }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> small = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        FakeDrawable *d = [FakeDrawable new];
        const int nf = argc > 2 ? atoi(argv[2]) : 40;
        for (int f = 0; f < nf; f++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            if (f % 10 == 9) {
                NSMutableArray *keep = [NSMutableArray new];
                for (int k = 0; k < 4; k++) [keep addObject:[dev newBufferWithLength:(64u << 20) options:MTLResourceStorageModePrivate]];
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1024 height:1024 mipmapped:NO];
                td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderRead;
                for (int k = 0; k < 3; k++) [keep addObject:[dev newTextureWithDescriptor:td]];
                NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
                    "kernel void k%d(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i * %du + 7u; }\n", f, f + 3];
                NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e];
                id<MTLComputePipelineState> ps = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:[NSString stringWithFormat:@"k%d", f]] error:&e] : nil;
                if (ps) { id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:ps]; [ce setBuffer:small offset:0 atIndex:0];
                          [ce dispatchThreads:MTLSizeMake(1024, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [ce endEncoding]; }
                else printf("frame %d: pipeline failed: %s\n", f, e.localizedDescription.UTF8String);
                usleep(30000);
            }
            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; [be fillBuffer:small range:NSMakeRange(0, 4096) value:(uint8_t)f]; [be endEncoding];
            [cb presentDrawable:d];
            [cb commit]; [cb waitUntilCompleted];
            usleep(5000);
        }
        printf("metal frames done (%u)\n", ((uint32_t *)small.contents)[0]);
        if (argc > 1 && !strcmp(argv[1], "gl")) {
            NSOpenGLPixelFormatAttribute at[] = { NSOpenGLPFAAccelerated, NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion4_1Core, 0 };
            NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:at];
            NSOpenGLContext *ctx = pf ? [[NSOpenGLContext alloc] initWithFormat:pf shareContext:nil] : nil;
            printf("gl context %s\n", ctx ? "made" : "NOT made");
            for (int f = 0; ctx && f < 8; f++) { usleep(f == 5 ? 40000 : 5000); [ctx flushBuffer]; }
            printf("gl frames done\n");
        }
    }
    return 0;
}
