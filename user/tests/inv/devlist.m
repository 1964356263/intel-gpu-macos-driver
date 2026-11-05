// SPDX-License-Identifier: MIT
// devlist: the system default Metal device and every device, as an app sees them (no bundle preload)
#import <Metal/Metal.h>
int main(void) { @autoreleasepool {
	id<MTLDevice> d = MTLCreateSystemDefaultDevice();
	printf("default: %s [%s] lowPower %d headless %d\n", d.name.UTF8String, NSStringFromClass([d class]).UTF8String, d.isLowPower, d.isHeadless);
	for (id<MTLDevice> x in MTLCopyAllDevices())
		printf("device: %s [%s] lowPower %d headless %d removable %d registryID %llx\n", x.name.UTF8String, NSStringFromClass([x class]).UTF8String,
		       x.isLowPower, x.isHeadless, x.isRemovable, x.registryID);
	return 0; } }
