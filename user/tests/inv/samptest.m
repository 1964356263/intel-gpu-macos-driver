// SPDX-License-Identifier: MIT
// samptest <icon.rgba>: the Dock icon draw as WindowServer's trace shows it - a 128x128 BGRA8 texture with 5 levels (box mips
// uploaded per level), drawn to 64x64 through a sampler min/mag linear, mip nearest, anisotropy 8 - written out per variant
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
static id<MTLDevice> bundleDevice(const char *path) {
	NSBundle *b = [NSBundle bundleWithPath:@(path)]; NSError *e = nil;
	if (![b loadAndReturnError:&e]) return nil;
	Class cls = [b classNamed:@"NVMTLDevice"]; io_iterator_t it = 0;
	IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it);
	id<MTLDevice> dev = nil;
	for (io_service_t svc; !dev && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
		CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
		if (name && CFEqual(name, CFSTR("NVMTLDevice"))) dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
		if (name) CFRelease(name); }
	return dev;
}
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
 "struct V { float4 p [[position]]; float2 uv; };\n"
 "vertex V vs(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V o; o.p = float4(q * 2 - 1, 0, 1); o.uv = float2(q.x, 1 - q.y); return o; }\n"
 "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, in.uv); }\n";
int main(int argc, char **argv) { @autoreleasepool {
	FILE *f = fopen(argv[1], "rb"); int w, h; fread(&w, 4, 1, f); fread(&h, 4, 1, f); uint8_t *p = malloc((size_t)w * h * 4); fread(p, 4, (size_t)w * h, f); fclose(f);
	for (int i = 0; i < w * h; i++) { uint8_t t = p[i * 4]; p[i * 4] = p[i * 4 + 2]; p[i * 4 + 2] = t; }   // RGBA -> BGRA
	const char *bp = getenv("NVMTL_BUNDLE"); id<MTLDevice> dev = bp ? bundleDevice(bp) : nil;
	if (!dev) for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) dev = d;
	NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&e]; if (!lib) { printf("lib %s\n", e.description.UTF8String); return 1; }
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
	id<MTLCommandQueue> q = [dev newCommandQueue];
	const char *names[] = { "upload-levels", "level0+generateMipmaps", "level0-only(autofill)" };
	for (int mode = 0; mode < 3; mode++) for (int an = 1; an <= 8; an *= 8) for (int mf = 1; mf <= 2; mf++) @autoreleasepool {
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:YES];
		td.mipmapLevelCount = 5; td.usage = MTLTextureUsageShaderRead;
		id<MTLTexture> t = [dev newTextureWithDescriptor:td];
		uint8_t *lv = malloc((size_t)w * h * 4); memcpy(lv, p, (size_t)w * h * 4); int s = w;
		[t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 slice:0 withBytes:lv bytesPerRow:w * 4 bytesPerImage:0];
		for (int l = 1; l < 5 && mode == 0; l++) { int n = s / 2; uint8_t *d = malloc((size_t)n * n * 4);
			for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) for (int c = 0; c < 4; c++)
				d[(y * n + x) * 4 + c] = (lv[((2*y) * s + 2*x) * 4 + c] + lv[((2*y) * s + 2*x+1) * 4 + c] + lv[((2*y+1) * s + 2*x) * 4 + c] + lv[((2*y+1) * s + 2*x+1) * 4 + c] + 2) / 4;
			[t replaceRegion:MTLRegionMake2D(0, 0, n, n) mipmapLevel:l slice:0 withBytes:d bytesPerRow:n * 4 bytesPerImage:0]; free(lv); lv = d; s = n; }
		free(lv);
		if (mode == 1) { id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b generateMipmapsForTexture:t]; [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; }
		MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; sd.mipFilter = mf; sd.maxAnisotropy = an;
		id<MTLSamplerState> ss = [dev newSamplerStateWithDescriptor:sd];
		MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
		rd.usage = MTLTextureUsageRenderTarget; rd.storageMode = MTLStorageModeManaged; id<MTLTexture> rt = [dev newTextureWithDescriptor:rd];
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
		[re setRenderPipelineState:ps]; [re setFragmentTexture:t atIndex:0]; [re setFragmentSamplerState:ss atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
		id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl synchronizeResource:rt]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
		uint8_t *o = malloc(64 * 64 * 4); [rt getBytes:o bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
		for (int i = 0; i < 64 * 64; i++) { uint8_t tt = o[i * 4]; o[i * 4] = o[i * 4 + 2]; o[i * 4 + 2] = tt; }
		char fn[96]; snprintf(fn, sizeof fn, "st_%d_aniso%d_mip%s.rgba", mode, an, mf == 1 ? "nearest" : "linear");
		FILE *g = fopen(fn, "wb"); int z = 64; fwrite(&z, 4, 1, g); fwrite(&z, 4, 1, g); fwrite(o, 4, 64 * 64, g); fclose(g);
		printf("%s %s\n", fn, names[mode]); free(o);
	}
	return 0;
} }
