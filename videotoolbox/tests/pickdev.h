// SPDX-License-Identifier: MIT
// pickdev.h: the Metal device of the IntelXe plugin (class NVMTLDevice), or the system's first device without it.
#pragma once
#import <Metal/Metal.h>
static id<MTLDevice> mtl_pick_intelxe(void) {
    NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
    for (id<MTLDevice> d in all)
        if ([NSStringFromClass([d class]) isEqualToString:@"NVMTLDevice"]) return d;
    return all.firstObject;
}
