// SPDX-License-Identifier: MIT
// devorder: Metal and OpenCL GPU device order as this process sees it.
// Built twice: devorder_nocg (Metal + OpenCL only, like a CLI worker) and devorder_cg (also links CoreGraphics and
// touches it, like an AppKit app).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <OpenCL/opencl.h>
#ifdef WITH_CG
#import <CoreGraphics/CoreGraphics.h>
#endif
#ifdef WITH_APPKIT
#import <AppKit/AppKit.h>
#endif
int main(void) {
	@autoreleasepool {
#ifdef WITH_APPKIT
		[NSApplication sharedApplication];
		printf("[AppKit NSApplication up] ");
#endif
#ifdef WITH_CG
		printf("[CoreGraphics linked] main display 0x%x\n", CGMainDisplayID());
#else
		printf("[no CoreGraphics]\n");
#endif
		NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
		int i = 0;
		for (id<MTLDevice> d in all)
			printf("metal[%d] %-30s regID 0x%llx headless %d lowPower %d removable %d location %lu/%lu peerGroup 0x%llx\n", i++,
			       d.name.UTF8String, d.registryID, d.isHeadless, d.isLowPower, d.isRemovable,
			       (unsigned long)d.location, (unsigned long)d.locationNumber, d.peerGroupID);
		id<MTLDevice> def = MTLCreateSystemDefaultDevice();
		printf("metal default: %s (0x%llx)\n", def ? def.name.UTF8String : "(none)", def ? def.registryID : 0);
		cl_platform_id plat[4]; cl_uint np = 0;
		clGetPlatformIDs(4, plat, &np);
		for (cl_uint p = 0; p < np; p++) {
			cl_device_id dev[8]; cl_uint nd = 0;
			clGetDeviceIDs(plat[p], CL_DEVICE_TYPE_GPU, 8, dev, &nd);
			for (cl_uint k = 0; k < nd; k++) {
				char name[128] = ""; cl_uint cu = 0;
				clGetDeviceInfo(dev[k], CL_DEVICE_NAME, sizeof name, name, NULL);
				clGetDeviceInfo(dev[k], CL_DEVICE_MAX_COMPUTE_UNITS, sizeof cu, &cu, NULL);
				printf("opencl[%u][%u] %s (CUs %u)\n", p, k, name, cu);
			}
		}
	}
	return 0;
}
