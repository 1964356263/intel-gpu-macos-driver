// SPDX-License-Identifier: MIT
// bt: newTextureWithDescriptor:offset:bytesPerRow: on MTLBuffers of each storage mode (Geekbench's MPS blur input,
// 1920x1080 RGBA8/BGRA8, bytesPerRow 7680): the texture must exist and sample the buffer's bytes
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
int main(void) { @autoreleasepool {
	const char *bp = getenv("NVMTL_BUNDLE"); id<MTLDevice> dev = bp ? bundleDevice(bp) : nil;
	if (!dev) for (id<MTLDevice> d in MTLCopyAllDevices()) if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) dev = d;
	if (!dev) { printf("no device\n"); return 2; }
	id<MTLCommandQueue> q = [dev newCommandQueue]; int fails = 0;
	const MTLStorageMode modes[3] = { MTLStorageModeShared, MTLStorageModeManaged, MTLStorageModePrivate };
	const MTLPixelFormat fmts[2] = { MTLPixelFormatRGBA8Unorm, MTLPixelFormatBGRA8Unorm };
	const NSUInteger W = 1920, H = 1080, row = 7680;
	for (int f = 0; f < 2; f++) for (int m = 0; m < 3; m++) @autoreleasepool {
		id<MTLBuffer> b = [dev newBufferWithLength:row * H options:(MTLResourceOptions)(modes[m] << MTLResourceStorageModeShift)];
		uint32_t *src = malloc(row * H); for (NSUInteger i = 0; i < W * H; i++) src[i] = 0xff000000u | (uint32_t)(i * 2654435761u >> 8);
		if (modes[m] == MTLStorageModePrivate) {
			id<MTLBuffer> up = [dev newBufferWithBytes:src length:row * H options:MTLResourceStorageModeShared];
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
			[e copyFromBuffer:up sourceOffset:0 toBuffer:b destinationOffset:0 size:row * H]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
		} else { memcpy(b.contents, src, row * H); if (modes[m] == MTLStorageModeManaged) [b didModifyRange:NSMakeRange(0, row * H)]; }
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmts[f] width:W height:H mipmapped:NO];
		td.storageMode = modes[m]; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
		id<MTLTexture> t = [b newTextureWithDescriptor:td offset:0 bytesPerRow:row];
		int bad = -1;
		if (t) {   // read it back through a texture-to-buffer blit and compare
			id<MTLBuffer> rb = [dev newBufferWithLength:row * H options:MTLResourceStorageModeShared];
			id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
			[e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * H];
			[e endEncoding]; [cb commit]; [cb waitUntilCompleted];
			bad = memcmp(rb.contents, src, row * H) != 0;
		}
		printf("  %s storage %d: texture %s%s\n", f ? "BGRA8" : "RGBA8", (int)modes[m], t ? "made" : "NIL", bad < 0 ? "" : bad ? ", contents WRONG" : ", contents match");
		fails += !t || bad; free(src);
	}
	printf("%s (%d)\n", fails ? "FAILED" : "PASSED", fails);
	return fails != 0;
} }
