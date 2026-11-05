// SPDX-License-Identifier: MIT
// mtl_bind: CPU cost of Metal resource binding per draw on the B580 Metal plugin (NVMTLDevice over our ANV), and a
// rendering correctness check (every mode draws a known image; the iGPU gives the reference).
// Build on the build Mac:
//   xcrun --sdk macosx clang -arch x86_64 -mmacosx-version-min=15.0 -fobjc-arc -O2 -o mtl_bind mtl_bind.m \
//     -framework Foundation -framework Metal -framework IOKit
// Run on the hackintosh:
//   NVMTL_ENABLE=1 ./mtl_bind [igpu] [-n draws] [-f frames] [-o outdir] [-loop sec] [mode...]
//   NVMTL_BUNDLE=<dir>/NVMTLDriver.bundle loads that plugin build instead of the installed one (nothing installed)
// Modes (each: frames x one render encoder of <draws> draws, 1024x1024 RGBA8 target, one quad per draw in a 64x64 grid):
//   none    pipeline + bindings set once, then only draws (the per-draw floor)
//   bytes   setVertexBytes + setFragmentBytes per draw (GL-style uniforms)
//   vbo     setVertexBufferOffset per draw (stage_in vertex buffer)
//   tex     setFragmentTexture per draw (8 textures)
//   samp    setFragmentSamplerState per draw (4 samplers)
//   gl      GL-like: setVertexBuffer + setVertexBytes + setFragmentBytes + 2 textures + 2 samplers per draw
//   argbuf  setFragmentBuffer of an argument buffer (texture + sampler + tint) per draw
//   pso     alternate two pipelines per draw + setVertexBytes
//   cdisp   compute: setBuffer + setBytes + dispatch per iteration (small kernels)
//   texbuf  texture_buffer (texel buffer) per draw, 2 of them
//   stex    compute writes one of 4 storage textures per dispatch (setTexture + setBytes), the draws then sample them
//   fetch   framebuffer fetch ([[color(0)]]) + setVertexBytes/setFragmentBytes per draw
//   glidx   GL-on-Metal like (Minecraft's terrain through Apple's GL): per draw setVertexBuffer (vertices) + setVertexBuffer
//           and setFragmentBuffer into shared uniform buffers + the same atlas texture + drawIndexedPrimitives
//   tess    tessellation: a compute pass writes the per-patch factors, then drawPatches (one triangle patch per draw)
//           with setVertexBytes + setFragmentTexture per draw
// Output: per mode, encode ns/draw (p50 and min over frames), commit->completed ms, image FNV hash; -o writes <mode>.rgba
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#include <mach/mach_time.h>
#include <stdlib.h>

static NSString *const kSource = @R"(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; float4 col; };
struct U { float4 rect; float4 col; };
static float4 cellpos(uint cell, float2 c, float4 rect) {
    float2 org = float2(cell % 64u, cell / 64u) / 64.0;
    float2 p = org + (rect.xy + c * rect.zw) / 64.0;
    return float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
}
constant float2 kQuad[6] = { float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(1,1), float2(0,1) };
vertex VOut vs_inst(uint vid [[vertex_id]], uint iid [[instance_id]], constant U &u [[buffer(1)]]) {
    VOut o; float2 c = kQuad[vid % 6u];
    o.pos = cellpos(iid & 4095u, c, u.rect); o.uv = c; o.col = u.col; return o;
}
struct VIn { float2 c [[attribute(0)]]; float2 uv [[attribute(1)]]; };
vertex VOut vs_vbo(VIn in [[stage_in]], uint iid [[instance_id]], constant U &u [[buffer(1)]]) {
    VOut o; o.pos = cellpos(iid & 4095u, in.c, u.rect); o.uv = in.uv; o.col = u.col; return o;
}
fragment float4 fs_tex(VOut in [[stage_in]], texture2d<float> t0 [[texture(0)]], sampler s0 [[sampler(0)]],
                       constant float4 &tint [[buffer(0)]]) {
    return t0.sample(s0, in.uv) * tint * in.col;
}
fragment float4 fs_tex2(VOut in [[stage_in]], texture2d<float> t0 [[texture(0)]], texture2d<float> t1 [[texture(1)]],
                        sampler s0 [[sampler(0)]], sampler s1 [[sampler(1)]], constant float4 &tint [[buffer(0)]]) {
    return t0.sample(s0, in.uv) * t1.sample(s1, in.uv * 2.0) * tint * in.col;
}
fragment float4 fs_flat(VOut in [[stage_in]], constant float4 &tint [[buffer(0)]]) { return tint * in.col; }
struct Mat { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; float4 tint [[id(2)]]; };
fragment float4 fs_arg(VOut in [[stage_in]], constant Mat &m [[buffer(2)]]) { return m.t.sample(m.s, in.uv) * m.tint * in.col; }
fragment float4 fs_tbuf(VOut in [[stage_in]], texture_buffer<float> tb [[texture(0)]], constant float4 &tint [[buffer(0)]]) {
    uint i = uint(in.uv.x * 15.0) + 16u * uint(in.uv.y * 15.0);
    return tb.read(i) * tint * in.col;
}
fragment float4 fs_fetch(VOut in [[stage_in]], float4 dst [[color(0)]], constant float4 &tint [[buffer(0)]]) {
    return dst * 0.5 + tint * in.col * 0.5;
}
kernel void kst(texture2d<float, access::write> o [[texture(0)]], constant float4 &k [[buffer(0)]],
                uint2 g [[thread_position_in_grid]]) {
    o.write(float4(float(g.x) / 16.0 * k.x, float(g.y) / 16.0 * k.y, k.z, 1.0), g);
}
kernel void ktf(device MTLTriangleTessellationFactorsHalf *f [[buffer(0)]], constant float &lvl [[buffer(1)]],
                uint i [[thread_position_in_grid]]) {
    half l = half(lvl + float(i & 3));
    f[i].edgeTessellationFactor[0] = l; f[i].edgeTessellationFactor[1] = l; f[i].edgeTessellationFactor[2] = l;
    f[i].insideTessellationFactor = l;
}
[[patch(triangle, 3)]]
vertex VOut vs_tess(uint pid [[patch_id]], float3 bc [[position_in_patch]], constant U &u [[buffer(1)]],
                    const device float2 *cps [[buffer(0)]]) {
    VOut o; float2 c = bc.x * cps[0] + bc.y * cps[1] + bc.z * cps[2];
    o.pos = cellpos(pid & 4095u, c, u.rect); o.uv = c; o.col = u.col * float4(bc, 1.0); return o;
}
kernel void ck(device float *o [[buffer(0)]], constant float4 &k [[buffer(1)]], device const float *in [[buffer(2)]],
               uint i [[thread_position_in_grid]]) { o[i] = fma(in[i], k.x, k.y) + float(i & 7u) * k.z; }
)";

static double now_ns(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom;
}
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

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

static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib;
static id<MTLTexture> rt, tex[8]; static id<MTLSamplerState> smp[4];
static id<MTLBuffer> vbo, rb, argb, cbufIn, cbufOut[4];
static id<MTLRenderPipelineState> psInst, psVbo, psTex2, psFlat, psArg, psTbuf, psFetch;
static id<MTLComputePipelineState> psCk, psKst, psTf;
static id<MTLRenderPipelineState> psTess; static id<MTLBuffer> tfBuf, cpBuf;
static id<MTLBuffer> ibuf, ubufV, ubufF;
static id<MTLTexture> tbuf[2], stx[4]; static id<MTLBuffer> tbufMem[2];
static NSUInteger argStride;
static int NDRAW = 2000, NFRAME = 30;
static const char *outdir;
enum { W = 1024 };

static id<MTLRenderPipelineState> rpso(NSString *vs, NSString *fs, MTLVertexDescriptor *vd) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:vs]; d.fragmentFunction = [lib newFunctionWithName:fs];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    d.colorAttachments[0].blendingEnabled = YES;   // additive-ish blend so draw order and every draw count
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne; d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne; d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    if (vd) d.vertexDescriptor = vd;
    NSError *e = nil; id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) { printf("pipeline %s/%s: %s\n", vs.UTF8String, fs.UTF8String, e.localizedDescription.UTF8String); exit(1); }
    return p;
}

typedef struct { float rect[4]; float col[4]; } U;
static U ufor(int k) {
    U u = { { 0.05f * (k % 3), 0.05f * ((k >> 2) % 3), 0.9f, 0.9f }, { 0.4f + 0.1f * (k % 7), 0.3f + 0.1f * (k % 5), 0.5f + 0.05f * (k % 9), 0.9f } };
    return u;
}
static void tintfor(int k, float t[4]) { t[0] = 1.0f - 0.03f * (k % 11); t[1] = 0.6f + 0.04f * (k % 9); t[2] = 0.8f; t[3] = 1.0f; }
static void setup(void) {
    NSError *e = nil;
    lib = [dev newLibraryWithSource:kSource options:nil error:&e];
    if (!lib) { printf("library: %s\n", e.localizedDescription.UTF8String); exit(1); }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:W mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
    rt = [dev newTextureWithDescriptor:td];
    rb = [dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    sd.usage = MTLTextureUsageShaderRead;
    uint8_t px[16 * 16 * 4];
    for (int t = 0; t < 8; t++) {
        tex[t] = [dev newTextureWithDescriptor:sd];
        for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) {
            uint8_t *p = px + (y * 16 + x) * 4;
            int chk = ((x >> (t & 3)) ^ (y >> ((t >> 2) + 1))) & 1;
            p[0] = (uint8_t)(40 + 25 * t + (chk ? 60 : 0)); p[1] = (uint8_t)(255 - 20 * t - x * 4); p[2] = (uint8_t)(y * 12 + t * 3); p[3] = 255;
        }
        [tex[t] replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0 withBytes:px bytesPerRow:64];
    }
    for (int s = 0; s < 4; s++) {
        MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
        d.minFilter = d.magFilter = (s & 1) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        d.sAddressMode = d.tAddressMode = (s & 2) ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        d.supportArgumentBuffers = YES;
        smp[s] = [dev newSamplerStateWithDescriptor:d];
    }
    // 8 quad variants of 6 vertices (c.xy, uv.xy): insets and uv flips
    float v[8][6][4];
    static const float qc[6][2] = { {0,0},{1,0},{0,1},{1,0},{1,1},{0,1} };
    for (int k = 0; k < 8; k++) for (int i = 0; i < 6; i++) {
        float in = 0.05f * (k & 3);
        v[k][i][0] = in + qc[i][0] * (1 - 2 * in); v[k][i][1] = in + qc[i][1] * (1 - 2 * in);
        v[k][i][2] = (k & 4) ? 1 - qc[i][0] : qc[i][0]; v[k][i][3] = qc[i][1];
    }
    vbo = [dev newBufferWithBytes:v length:sizeof v options:MTLResourceStorageModeShared];
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat2; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 0;
    vd.layouts[0].stride = 16;
    psInst = rpso(@"vs_inst", @"fs_tex", nil);
    psVbo = rpso(@"vs_vbo", @"fs_tex", vd);
    psTex2 = rpso(@"vs_vbo", @"fs_tex2", vd);
    psFlat = rpso(@"vs_inst", @"fs_flat", nil);
    psArg = rpso(@"vs_inst", @"fs_arg", nil);
    psTbuf = rpso(@"vs_inst", @"fs_tbuf", nil);
    psFetch = rpso(@"vs_inst", @"fs_fetch", nil);
    for (int b = 0; b < 2; b++) {
        uint8_t tp[256 * 4];
        for (int i = 0; i < 256; i++) { tp[i * 4] = (uint8_t)(i * (b + 1)); tp[i * 4 + 1] = (uint8_t)(255 - i); tp[i * 4 + 2] = (uint8_t)(b ? 200 : 60); tp[i * 4 + 3] = 255; }
        tbufMem[b] = [dev newBufferWithBytes:tp length:sizeof tp options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *bd = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256
                                                            resourceOptions:MTLResourceStorageModeShared usage:MTLTextureUsageShaderRead];
        tbuf[b] = [tbufMem[b] newTextureWithDescriptor:bd offset:0 bytesPerRow:256 * 4];
    }
    MTLTextureDescriptor *wd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    wd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; wd.storageMode = MTLStorageModePrivate;
    for (int t = 0; t < 4; t++) stx[t] = [dev newTextureWithDescriptor:wd];
    id<MTLFunction> fa = [lib newFunctionWithName:@"fs_arg"];
    id<MTLArgumentEncoder> ae = [fa newArgumentEncoderWithBufferIndex:2];
    if (ae) {
        argStride = (ae.encodedLength + 255) & ~(NSUInteger)255;
        argb = [dev newBufferWithLength:argStride * 32 options:MTLResourceStorageModeShared];
        for (int k = 0; k < 32; k++) {
            [ae setArgumentBuffer:argb offset:argStride * k];
            [ae setTexture:tex[k & 7] atIndex:0]; [ae setSamplerState:smp[(k >> 3) & 3] atIndex:1];
            float *tint = (float *)[ae constantDataAtIndex:2];
            tint[0] = 0.5f + 0.015f * k; tint[1] = 1.0f - 0.02f * k; tint[2] = 0.3f + 0.02f * (k & 7); tint[3] = 1.0f;
        }
    }
    {   // glidx: an index buffer and per-draw uniform slices in shared buffers
        const uint16_t idx[6] = { 0, 1, 2, 3, 4, 5 };
        ibuf = [dev newBufferWithBytes:idx length:sizeof idx options:MTLResourceStorageModeShared];
        ubufV = [dev newBufferWithLength:4096 * 256 options:MTLResourceStorageModeShared];
        ubufF = [dev newBufferWithLength:4096 * 256 options:MTLResourceStorageModeShared];
        for (int k = 0; k < 4096; k++) {
            U u = ufor(k); memcpy((uint8_t *)ubufV.contents + (size_t)k * 256, &u, sizeof u);
            float tv[4]; tintfor(k, tv); memcpy((uint8_t *)ubufF.contents + (size_t)k * 256, tv, sizeof tv);
        }
    }
    {   // tessellation (tess mode)
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vs_tess"]; d.fragmentFunction = [lib newFunctionWithName:@"fs_tex"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        d.tessellationPartitionMode = MTLTessellationPartitionModeInteger; d.maxTessellationFactor = 16;
        d.tessellationFactorFormat = MTLTessellationFactorFormatHalf; d.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionPerPatch;
        d.tessellationOutputWindingOrder = MTLWindingCounterClockwise; d.tessellationControlPointIndexType = MTLTessellationControlPointIndexTypeNone;
        psTess = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        if (!psTess) printf("tess pipeline: %s (tess mode skipped)\n", e.localizedDescription.UTF8String);
        psTf = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"ktf"] error:&e];
        tfBuf = [dev newBufferWithLength:4096 * 8 options:MTLResourceStorageModePrivate];
        const float cp[6] = { 0.05f, 0.05f, 0.95f, 0.1f, 0.4f, 0.95f };
        cpBuf = [dev newBufferWithBytes:cp length:sizeof cp options:MTLResourceStorageModeShared];
    }
    psKst = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"kst"] error:&e];
    if (!psKst) { printf("compute pipeline kst: %s\n", e.localizedDescription.UTF8String); exit(1); }
    psCk = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"ck"] error:&e];
    if (!psCk) { printf("compute pipeline: %s\n", e.localizedDescription.UTF8String); exit(1); }
    float *ci = malloc(4096 * 4); for (int i = 0; i < 4096; i++) ci[i] = (float)i * 0.25f;
    cbufIn = [dev newBufferWithBytes:ci length:4096 * 4 options:MTLResourceStorageModeShared]; free(ci);
    for (int i = 0; i < 4; i++) cbufOut[i] = [dev newBufferWithLength:4096 * 4 options:MTLResourceStorageModeShared];
}


// one frame of mode m; returns encode ns (render encoder creation .. endEncoding) and fills commit->complete ns
static double frame(const char *m, double *gpu_ns, double *wait_ns) {
    id<MTLCommandBuffer> cb = [q commandBuffer];
    double t0 = now_ns();
    if (!strcmp(m, "cdisp")) {
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:psCk];
        [ce setBuffer:cbufIn offset:0 atIndex:2];
        for (int k = 0; k < NDRAW; k++) {
            float kk[4] = { 1.0f + 0.001f * (k & 15), 0.5f, 0.125f, 0 };
            [ce setBuffer:cbufOut[k & 3] offset:(NSUInteger)((k >> 2) & 3) * 1024 * 4 atIndex:0];
            [ce setBytes:kk length:16 atIndex:1];
            [ce dispatchThreads:MTLSizeMake(1024, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        }
        [ce endEncoding];
    } else {
        if (!strcmp(m, "tess")) {   // the patches' factors
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            const float lvl = 2.0f;
            [ce setComputePipelineState:psTf]; [ce setBuffer:tfBuf offset:0 atIndex:0]; [ce setBytes:&lvl length:4 atIndex:1];
            [ce dispatchThreads:MTLSizeMake((NSUInteger)NDRAW, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [ce endEncoding];
        }
        if (!strcmp(m, "stex")) {   // the storage textures the draws sample, written per dispatch
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:psKst];
            for (int k = 0; k < NDRAW; k++) {
                float kk[4] = { 0.5f + 0.1f * (k & 3), 1.0f - 0.05f * ((k >> 2) & 7), 0.25f * ((k >> 5) & 3), 0 };
                [ce setTexture:stx[k & 3] atIndex:0];
                [ce setBytes:kk length:16 atIndex:0];
                [ce dispatchThreads:MTLSizeMake(16, 16, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            }
            [ce endEncoding];
        }
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.15, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        U u0 = ufor(0); float t0v[4]; tintfor(0, t0v);
        const BOOL vb = !strcmp(m, "vbo") || !strcmp(m, "gl") || !strcmp(m, "glidx");
        [e setRenderPipelineState:(!strcmp(m, "gl") || !strcmp(m, "glidx")) ? psTex2 : vb ? psVbo : !strcmp(m, "argbuf") ? psArg : !strcmp(m, "texbuf") ? psTbuf :
                                  !strcmp(m, "fetch") ? psFetch : !strcmp(m, "tess") ? psTess : psInst];
        if (!strcmp(m, "tess")) { [e setTessellationFactorBuffer:tfBuf offset:0 instanceStride:0]; [e setVertexBuffer:cpBuf offset:0 atIndex:0]; }
        [e setVertexBytes:&u0 length:sizeof u0 atIndex:1];
        [e setFragmentBytes:t0v length:16 atIndex:0];
        [e setFragmentTexture:tex[0] atIndex:0]; [e setFragmentTexture:tex[1] atIndex:1];
        [e setFragmentSamplerState:smp[0] atIndex:0]; [e setFragmentSamplerState:smp[1] atIndex:1];
        if (vb) [e setVertexBuffer:vbo offset:0 atIndex:0];
        if (!strcmp(m, "argbuf")) { for (int t = 0; t < 8; t++) [e useResource:tex[t] usage:MTLResourceUsageRead stages:MTLRenderStageFragment]; }
        for (int k = 0; k < NDRAW; k++) {
            if (!strcmp(m, "texbuf")) [e setFragmentTexture:tbuf[k & 1] atIndex:0];
            if (!strcmp(m, "stex")) [e setFragmentTexture:stx[k & 3] atIndex:0];
            if (!strcmp(m, "bytes") || !strcmp(m, "pso") || !strcmp(m, "gl") || !strcmp(m, "fetch")) {
                U u = ufor(k); float tv[4]; tintfor(k, tv);
                if (!strcmp(m, "pso")) [e setRenderPipelineState:(k & 1) ? psFlat : psInst];
                [e setVertexBytes:&u length:sizeof u atIndex:1];
                if (strcmp(m, "pso")) [e setFragmentBytes:tv length:16 atIndex:0];
            }
            if (!strcmp(m, "vbo")) [e setVertexBufferOffset:(NSUInteger)(k & 7) * 96 atIndex:0];
            if (!strcmp(m, "tex")) [e setFragmentTexture:tex[k & 7] atIndex:0];
            if (!strcmp(m, "samp")) [e setFragmentSamplerState:smp[k & 3] atIndex:0];
            if (!strcmp(m, "gl")) {
                [e setVertexBuffer:vbo offset:(NSUInteger)(k & 7) * 96 atIndex:0];
                [e setFragmentTexture:tex[k & 7] atIndex:0]; [e setFragmentTexture:tex[(k + 3) & 7] atIndex:1];
                [e setFragmentSamplerState:smp[k & 1] atIndex:0]; [e setFragmentSamplerState:smp[2 + ((k >> 1) & 1)] atIndex:1];
            }
            if (!strcmp(m, "argbuf")) [e setFragmentBuffer:argb offset:argStride * (NSUInteger)(k & 31) atIndex:2];
            if (!strcmp(m, "glidx")) {
                [e setVertexBuffer:vbo offset:(NSUInteger)(k & 7) * 96 atIndex:0];
                [e setVertexBuffer:ubufV offset:(NSUInteger)(k & 4095) * 256 atIndex:1];
                [e setFragmentBuffer:ubufF offset:(NSUInteger)(k & 4095) * 256 atIndex:0];
                [e setFragmentTexture:tex[0] atIndex:0]; [e setFragmentTexture:tex[1] atIndex:1];
                [e setFragmentSamplerState:smp[0] atIndex:0]; [e setFragmentSamplerState:smp[3] atIndex:1];
                [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16 indexBuffer:ibuf
                       indexBufferOffset:0 instanceCount:1 baseVertex:0 baseInstance:(NSUInteger)k];
                continue;
            }
            if (!strcmp(m, "tess")) {
                U u = ufor(k); [e setVertexBytes:&u length:sizeof u atIndex:1]; [e setFragmentTexture:tex[k & 7] atIndex:0];
                [e drawPatches:3 patchStart:(NSUInteger)k patchCount:1 patchIndexBuffer:nil patchIndexBufferOffset:0 instanceCount:1 baseInstance:0];
                continue;
            }
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:(NSUInteger)k];
        }
        [e endEncoding];
    }
    double enc = now_ns() - t0;
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    if (strcmp(m, "cdisp"))
        [b copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1)
                  toBuffer:rb destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [b endEncoding];
    double t1 = now_ns();
    [cb commit]; [cb waitUntilCompleted];
    *wait_ns = now_ns() - t1;
    *gpu_ns = (cb.GPUEndTime - cb.GPUStartTime) * 1e9;
    if (cb.status != MTLCommandBufferStatusCompleted) printf("  command buffer status %ld error %s\n", (long)cb.status, cb.error.description.UTF8String);
    return enc;
}

static uint64_t fnv(const uint8_t *p, size_t n) { uint64_t h = 1469598103934665603ull; for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; } return h; }

static void run(const char *m) {
    if (!strcmp(m, "tess") && !psTess) { printf("%-7s SKIPPED (no tessellation pipeline)\n", m); return; }
    if (!strcmp(m, "argbuf") && !argb) { printf("%-7s SKIPPED (no argument encoder)\n", m); return; }
    double g, w, *enc = calloc(NFRAME, 8), *wt = calloc(NFRAME, 8), *gp = calloc(NFRAME, 8);
    for (int i = 0; i < 3; i++) @autoreleasepool { frame(m, &g, &w); }   // warm-up (pipelines, variants, pools)
    double c0 = (double)clock();
    double t0 = now_ns();
    for (int i = 0; i < NFRAME; i++) @autoreleasepool { enc[i] = frame(m, &gp[i], &wt[i]); }
    double wall = now_ns() - t0, cpu = ((double)clock() - c0) / CLOCKS_PER_SEC * 1e9;
    qsort(enc, NFRAME, 8, dcmp); qsort(wt, NFRAME, 8, dcmp); qsort(gp, NFRAME, 8, dcmp);
    uint64_t h = 0;
    if (strcmp(m, "cdisp")) {
        h = fnv(rb.contents, W * W * 4);
        if (outdir) {
            char path[1024]; snprintf(path, sizeof path, "%s/%s.rgba", outdir, m);
            FILE *f = fopen(path, "wb"); if (f) { fwrite(rb.contents, 1, W * W * 4, f); fclose(f); }
        }
    } else {
        for (int i = 0; i < 4; i++) h ^= fnv(cbufOut[i].contents, 4096 * 4) * (uint64_t)(i + 1);
        if (outdir) {
            char path[1024]; snprintf(path, sizeof path, "%s/%s.bin", outdir, m);
            FILE *f = fopen(path, "wb"); if (f) { for (int i = 0; i < 4; i++) fwrite(cbufOut[i].contents, 1, 4096 * 4, f); fclose(f); }
        }
    }
    printf("%-7s enc/draw p50 %7.0f min %7.0f ns | enc/frame p50 %6.2f ms | commit->done p50 %6.2f ms | gpu p50 %6.2f ms | cpu/frame %6.2f ms wall/frame %6.2f ms | hash %016llx\n",
           m, enc[NFRAME / 2] / NDRAW, enc[0] / NDRAW, enc[NFRAME / 2] / 1e6, wt[NFRAME / 2] / 1e6, gp[NFRAME / 2] / 1e6,
           cpu / NFRAME / 1e6, wall / NFRAME / 1e6, (unsigned long long)h);
    fflush(stdout);
    free(enc); free(wt); free(gp);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL igpu = NO; double loop = 0;
        const char *modes[32]; int nm = 0;
        for (int a = 1; a < argc; a++) {
            if (!strcmp(argv[a], "igpu")) igpu = YES;
            else if (!strcmp(argv[a], "-n") && a + 1 < argc) NDRAW = atoi(argv[++a]);
            else if (!strcmp(argv[a], "-f") && a + 1 < argc) NFRAME = atoi(argv[++a]);
            else if (!strcmp(argv[a], "-o") && a + 1 < argc) outdir = argv[++a];
            else if (!strcmp(argv[a], "-loop") && a + 1 < argc) loop = atof(argv[++a]);
            else if (nm < 32) modes[nm++] = argv[a];
        }
        if (NDRAW < 1) NDRAW = 1;
        if (NFRAME < 1) NFRAME = 1;
        const char *bundle = getenv("NVMTL_BUNDLE");
        if (bundle && !igpu) dev = bundleDevice(bundle);
        else for (id<MTLDevice> d in MTLCopyAllDevices()) {
            BOOL nv = [NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"];
            if (igpu ? !nv : nv) dev = d;
        }
        if (!dev) { printf("no %s Metal device\n", igpu ? "iGPU" : "B580 (NVMTLDevice)"); return 2; }
        printf("device: %s (%s)%s%s | draws/frame %d frames %d\n", dev.name.UTF8String, NSStringFromClass([dev class]).UTF8String,
               bundle && !igpu ? " bundle " : "", bundle && !igpu ? bundle : "", NDRAW, NFRAME);
        q = [dev newCommandQueue];
        setup();
        static const char *all[] = { "none", "bytes", "vbo", "tex", "samp", "gl", "argbuf", "pso", "cdisp", "texbuf", "stex", "fetch", "tess", "glidx" };
        if (!nm) { for (int i = 0; i < 14; i++) modes[nm++] = all[i]; }
        if (loop > 0) {   // keep one mode running for sample(1)
            double end = now_ns() + loop * 1e9, g, w; long n = 0;
            while (now_ns() < end) @autoreleasepool { frame(modes[0], &g, &w); n++; }
            printf("loop %s: %ld frames in %.1f s\n", modes[0], n, loop);
            return 0;
        }
        for (int i = 0; i < nm; i++) run(modes[i]);
    }
    return 0;
}
