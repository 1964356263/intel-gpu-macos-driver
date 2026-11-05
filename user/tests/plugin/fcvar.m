// SPDX-License-Identifier: MIT
// fcvar: CoreAnimation's uber shader (QuartzCore default.metallib, fixed_frag_lph_cph + fixed_vert_lph_gen) built with
// a series of function-constant variants. Per variant: time of newFunctionWithName:constantValues: (the translation),
// time of newRenderPipelineStateWithDescriptor: (ANV's compile), one draw into a 64x64 BGRA8 target with checkerboard
// textures and constant buffers bound, and the FNV hash of the result. Run it twice with the same variants, once with
// NVMTL_FC_SPEC=0 (each variant translated whole) and once without (specialization constants): equal hashes per variant
// mean the two paths render the same.
//   NVMTL_BUNDLE=<dir>/NVMTLDriver.bundle fcvar [-n variants] [-f fragment function] [-r repeats] [-w ms idle after loading]
// Nothing is installed; the plugin's caches are the process's own (NVMTL_FCCACHE_OFF=1 to time cold translations).
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#include <mach/mach_time.h>

static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e6; }

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

// the fragment function's constants (index, Metal type, lanes): fixed_frag_lph_cph / _cpf / lpf_cpf share them
typedef struct { uint16_t index; MTLDataType type; uint8_t lanes; } FC;
static const FC kFrag[] = {
    {0,MTLDataTypeBool,1},{3,MTLDataTypeUChar,1},{4,MTLDataTypeBool,1},{5,MTLDataTypeUChar,1},{7,MTLDataTypeBool,1},
    {8,MTLDataTypeBool,1},{9,MTLDataTypeBool,1},{10,MTLDataTypeBool,1},{11,MTLDataTypeBool,1},{12,MTLDataTypeBool,1},
    {13,MTLDataTypeBool,1},{14,MTLDataTypeBool,1},{15,MTLDataTypeBool,1},{16,MTLDataTypeBool,1},{17,MTLDataTypeBool,1},
    {18,MTLDataTypeBool,1},{19,MTLDataTypeBool,1},{20,MTLDataTypeBool,1},{21,MTLDataTypeBool,1},{22,MTLDataTypeBool,1},
    {23,MTLDataTypeBool,1},{24,MTLDataTypeBool,1},{25,MTLDataTypeBool,1},{26,MTLDataTypeBool,1},{27,MTLDataTypeBool,1},
    {28,MTLDataTypeUChar,1},{29,MTLDataTypeUChar,1},{31,MTLDataTypeUChar,1},{32,MTLDataTypeUChar,1},{34,MTLDataTypeUChar,1},
    {35,MTLDataTypeUChar,1},{36,MTLDataTypeUChar,1},{37,MTLDataTypeBool,1},{38,MTLDataTypeBool,1},{39,MTLDataTypeBool,1},
    {40,MTLDataTypeBool,1},{41,MTLDataTypeBool,1},{42,MTLDataTypeBool,1},{43,MTLDataTypeBool,1},{45,MTLDataTypeUChar,1},
    {46,MTLDataTypeUChar,1},{47,MTLDataTypeUChar,1},{48,MTLDataTypeUChar,1},{49,MTLDataTypeUChar,1},{50,MTLDataTypeUChar,1},
    {51,MTLDataTypeUChar,1},{52,MTLDataTypeUChar,1},{53,MTLDataTypeUChar,1},{54,MTLDataTypeUChar,1},{55,MTLDataTypeUChar,1},
    {56,MTLDataTypeUChar,1},{57,MTLDataTypeUChar4,4},{58,MTLDataTypeUChar4,4},{59,MTLDataTypeUChar2,2},{60,MTLDataTypeUChar2,2},
    {61,MTLDataTypeBool,1},{62,MTLDataTypeBool,1},{63,MTLDataTypeUChar,1},{64,MTLDataTypeUChar,1},
};
#define NFRAG (sizeof kFrag / sizeof kFrag[0])

// Variant v: a deterministic value per constant. Variant 0 is a plain one-image composite; the others turn on images,
// texture/blend/destination functions, colour opcodes and the generic path in turn.
static uint8_t value_for(int v, uint16_t index, int lane) {
    uint32_t h = 2166136261u ^ (uint32_t)v * 16777619u; h = (h ^ index) * 16777619u; h = (h ^ (uint32_t)lane) * 16777619u;
    switch (index) {
        case 0: return v >= 6;                                   // fc_generic
        case 3: return 0;                                        // fc_vertex_layout
        case 4: return 0;                                        // fc_framebuffer_fetch (no input attachments here)
        case 5: return 1;                                        // fc_attachment_count
        case 12: return 1;                                       // fc_has_attachment_0
        case 13: case 14: return 0;
        case 15: return 1;                                       // fc_has_image_0A
        case 16: return v >= 2;                                  // fc_has_image_1A
        case 28: return (uint8_t)(v % 4);                        // fc_texture_function
        case 29: return (uint8_t)((v * 3) % 5);                  // fc_blend_function
        case 31: return (uint8_t)(v % 3);                        // fc_destination_function
        case 32: return v >= 2 ? 2 : 1;                          // fc_image_count
        case 34: return 0;                                       // fc_dest_index
        case 35: return 1;                                       // fc_dest_count
        case 36: return 8;                                       // fc_noise_width
        case 49: case 50: return 1;                              // plane counts
        case 51: case 52: return 1;                              // texcoord counts
        case 53: case 54: return 0;                              // memoryless indices
        case 55: case 56: return (uint8_t)(v >= 4 ? 1 + v % 2 : 0); // colour program inputs
        case 57: case 58: return (uint8_t)(v >= 4 ? h % 6 : 0);  // colour opcodes
        case 59: case 60: return 0;
        case 63: case 64: return (uint8_t)(v % 2);               // filters
        default: return (uint8_t)(v >= 3 ? (h >> 7) & 1 : 0);    // the remaining booleans
    }
}

static uint64_t fnv(const uint8_t *p, size_t n) { uint64_t h = 1469598103934665603ull; for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ull; return h; }

int main(int argc, char **argv) {
    @autoreleasepool {
        int nvar = 8, reps = 1, waitms = 0; const char *frag = "fixed_frag_lph_cph";
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "-n") && i + 1 < argc) nvar = atoi(argv[++i]);
            else if (!strcmp(argv[i], "-r") && i + 1 < argc) reps = atoi(argv[++i]);
            else if (!strcmp(argv[i], "-f") && i + 1 < argc) frag = argv[++i];
            else if (!strcmp(argv[i], "-w") && i + 1 < argc) waitms = atoi(argv[++i]);   // idle after loading the library
        }
        const char *bundle = getenv("NVMTL_BUNDLE");
        id<MTLDevice> dev = nil;
        if (bundle) dev = bundleDevice(bundle);
        else for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) dev = d;
        if (!dev) { printf("no B580 (NVMTLDevice) Metal device\n"); return 2; }
        printf("device %s, NVMTL_FC_SPEC=%s, fragment %s\n", dev.name.UTF8String, getenv("NVMTL_FC_SPEC") ?: "(default)", frag);
        NSError *err = nil;
        NSURL *url = [NSURL fileURLWithPath:@"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib"];
        double t = now_ms();
        id<MTLLibrary> lib = [dev newLibraryWithURL:url error:&err];
        if (!lib) { printf("library: %s\n", err.localizedDescription.UTF8String); return 3; }
        printf("library: %lu functions, %.1f ms\n", (unsigned long)lib.functionNames.count, now_ms() - t);
        if (waitms > 0) usleep((useconds_t)waitms * 1000);
        id<MTLCommandQueue> q = [dev newCommandQueue];

        // resources: checkerboard textures 0..7, samplers 0..3, buffers 0..15 of 0.5f, a vertex buffer of quad-ish floats
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex[8];
        for (int k = 0; k < 8; k++) {
            tex[k] = [dev newTextureWithDescriptor:td];
            uint32_t px[64 * 64];
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++)
                px[y * 64 + x] = ((x / 8 + y / 8 + k) & 1) ? 0xff2080e0u + (uint32_t)k * 0x1020 : 0xc0e04010u + (uint32_t)(x * 3 + y);
            [tex[k] replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:px bytesPerRow:256];
        }
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
        float fb[1024]; for (int k = 0; k < 1024; k++) fb[k] = 0.5f + 0.25f * (float)((k * 7) % 5) / 4.0f;
        id<MTLBuffer> buf = [dev newBufferWithBytes:fb length:sizeof fb options:MTLResourceStorageModeShared];
        float vb[6 * 16]; static const float quad[6][2] = {{-1,-1},{1,-1},{-1,1},{-1,1},{1,-1},{1,1}};
        for (int v = 0; v < 6; v++) for (int k = 0; k < 16; k++) vb[v * 16 + k] = k < 2 ? quad[v][k] * 0.9f : (k == 3 ? 1.0f : (quad[v][k & 1] + 1) * 0.5f);
        id<MTLBuffer> vbuf = [dev newBufferWithBytes:vb length:sizeof vb options:MTLResourceStorageModeShared];
        uint8_t vcfg[4] = { 1, 0, 0, 0 };
        float mvp[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
        rd.usage = MTLTextureUsageRenderTarget; rd.storageMode = MTLStorageModeShared;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:rd];

        double sumFn = 0, sumPso = 0;
        for (int r = 0; r < reps; r++) for (int v = 0; v < nvar; v++) @autoreleasepool {
            MTLFunctionConstantValues *fcv = [MTLFunctionConstantValues new];
            for (size_t k = 0; k < NFRAG; k++) {
                uint8_t b[4]; for (int l = 0; l < kFrag[k].lanes; l++) b[l] = value_for(v, kFrag[k].index, l);
                [fcv setConstantValue:b type:kFrag[k].type atIndex:kFrag[k].index];
            }
            MTLFunctionConstantValues *vcv = [MTLFunctionConstantValues new];
            uint8_t g = value_for(v, 0, 0), one = 1, zero = 0;
            [vcv setConstantValue:&g type:MTLDataTypeBool atIndex:0];
            [vcv setConstantValue:&zero type:MTLDataTypeBool atIndex:1];
            [vcv setConstantValue:&zero type:MTLDataTypeUChar atIndex:3];
            [vcv setConstantValue:&one type:MTLDataTypeUChar atIndex:51];
            [vcv setConstantValue:&one type:MTLDataTypeUChar atIndex:52];
            double t0 = now_ms();
            id<MTLFunction> ff = [lib newFunctionWithName:@(frag) constantValues:fcv error:&err];
            double t1 = now_ms();
            // the vertex stage: CoreAnimation's own, or (default) a source one that writes the fragment function's
            // varyings (same member names and types, so the same generated user semantics) over the whole target
            static id<MTLFunction> srcVs;
            if (!srcVs && !getenv("FCVAR_CA_VS")) {
                NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                    "struct VOut { float4 position [[position]]; float2 texcoord0A; float2 texcoord1A; float2 texcoord0B; float2 texcoord1B; half4 color; };\n"
                    "vertex VOut fcvar_vs(uint vid [[vertex_id]]) {\n"
                    "  const float2 p[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,1), float2(1,-1), float2(1,1) };\n"
                    "  VOut o; float2 q = p[vid]; o.position = float4(q, 0, 1); float2 t = q * 0.5 + 0.5;\n"
                    "  o.texcoord0A = t; o.texcoord1A = t.yx; o.texcoord0B = t * 2.0; o.texcoord1B = 1.0 - t;\n"
                    "  o.color = half4(0.9h, 0.6h, 0.3h, 0.8h); return o; }\n";
                id<MTLLibrary> vl = [dev newLibraryWithSource:src options:nil error:&err];
                srcVs = [vl newFunctionWithName:@"fcvar_vs"];
                if (!srcVs) printf("source vertex function: %s - CoreAnimation's is used\n", err.localizedDescription.UTF8String);
            }
            id<MTLFunction> vf = srcVs ?: [lib newFunctionWithName:@"fixed_vert_lph_gen" constantValues:vcv error:&err];
            if (!ff || !vf) { printf("variant %d: function: %s\n", v, err.localizedDescription.UTF8String); continue; }
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = vf; pd.fragmentFunction = ff; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            double t2 = now_ms();
            id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
            double t3 = now_ms();
            if (!ps) { printf("variant %d: pipeline: %s\n", v, err.localizedDescription.UTF8String); continue; }
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2, 0.3, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
            [en setRenderPipelineState:ps];
            [en setVertexBytes:vcfg length:sizeof vcfg atIndex:0];
            [en setVertexBuffer:vbuf offset:0 atIndex:1];
            [en setVertexBytes:mvp length:sizeof mvp atIndex:2];
            [en setVertexBytes:mvp length:16 atIndex:3];
            [en setVertexBytes:mvp length:16 atIndex:4];
            for (int k = 0; k < 16; k++) [en setFragmentBuffer:buf offset:(NSUInteger)k * 256 atIndex:(NSUInteger)k];
            for (int k = 0; k < 8; k++) [en setFragmentTexture:tex[k] atIndex:(NSUInteger)k];
            for (int k = 0; k < 4; k++) [en setFragmentSamplerState:smp atIndex:(NSUInteger)k];
            [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [en endEncoding];
            [cb commit]; [cb waitUntilCompleted];
            uint8_t px[64 * 64 * 4];
            [rt getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
            printf("variant %d%s: function %.1f ms, pipeline %.1f ms, %s, image %016llx (centre %02x%02x%02x%02x)\n", v, r ? " (again)" : "",
                   t1 - t0, t3 - t2, cb.status == MTLCommandBufferStatusCompleted ? "completed" : "NOT completed",
                   (unsigned long long)fnv(px, sizeof px), px[(32 * 64 + 32) * 4 + 2], px[(32 * 64 + 32) * 4 + 1],
                   px[(32 * 64 + 32) * 4], px[(32 * 64 + 32) * 4 + 3]);
            if (!r) { sumFn += t1 - t0; sumPso += t3 - t2; }
        }
        printf("first pass: function %.1f ms, pipeline %.1f ms in all (%d variants)\n", sumFn, sumPso, nvar);
    }
    return 0;
}
