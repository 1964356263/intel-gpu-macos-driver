// SPDX-License-Identifier: MIT
// nvmtl_interpose.dylib: with NVMTL_BUNDLE=<path>/NVMTLDriver.bundle, Metal's device entry points return a device made
// from that plugin build, so a GL (AppleMetalOpenGLRenderer) or Metal app runs on a staged plugin without installing it.
// DYLD_INSERT_LIBRARIES=nvmtl_interpose.dylib; test use only. Prints each interposed call once to stderr.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#include <os/lock.h>

static id<MTLDevice> g_dev;
static id<MTLDevice> bundle_device(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *path = getenv("NVMTL_BUNDLE");
        if (!path) return;
        NSBundle *b = [NSBundle bundleWithPath:@(path)]; NSError *e = nil;
        if (![b loadAndReturnError:&e]) { fprintf(stderr, "interpose: bundle %s: %s\n", path, e.localizedDescription.UTF8String); return; }
        Class cls = [b classNamed:@"NVMTLDevice"];
        if (!cls) { fprintf(stderr, "interpose: no NVMTLDevice in %s\n", path); return; }
        io_iterator_t it = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return;
        for (io_service_t svc; !g_dev && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
            CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
            if (name && CFEqual(name, CFSTR("NVMTLDevice")))
                g_dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
            if (name) CFRelease(name);
        }
        IOObjectRelease(it);
        fprintf(stderr, "interpose: device %s from %s\n", g_dev ? g_dev.name.UTF8String : "(none)", path);
    });
    return g_dev;
}
static void said(const char *fn) {
    static NSMutableSet *seen; static os_unfair_lock l = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&l); if (!seen) seen = [NSMutableSet new];
    BOOL fresh = ![seen containsObject:@(fn)]; if (fresh) [seen addObject:@(fn)]; os_unfair_lock_unlock(&l);
    if (fresh) fprintf(stderr, "interpose: %s called\n", fn);
}
static id<MTLDevice> my_default(void) NS_RETURNS_RETAINED;
static id<MTLDevice> my_default(void) {
    said("MTLCreateSystemDefaultDevice");
    id<MTLDevice> d = bundle_device(); return d ? d : MTLCreateSystemDefaultDevice();
}
static NSArray<id<MTLDevice>> *my_all(void) NS_RETURNS_RETAINED;
static NSArray<id<MTLDevice>> *my_all(void) {
    said("MTLCopyAllDevices");
    id<MTLDevice> d = bundle_device(); return d ? @[d] : MTLCopyAllDevices();
}
static NSArray<id<MTLDevice>> *my_all_obs(id<NSObject> __strong *obs, MTLDeviceNotificationHandler h) NS_RETURNS_RETAINED;
static NSArray<id<MTLDevice>> *my_all_obs(id<NSObject> __strong *obs, MTLDeviceNotificationHandler h) {
    said("MTLCopyAllDevicesWithObserver");
    id<MTLDevice> d = bundle_device(); if (d) { if (obs) *obs = nil; return @[d]; }
    return MTLCopyAllDevicesWithObserver(obs, h);
}
__attribute__((used)) static struct { const void *rep, *orig; } interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)my_default, (const void *)MTLCreateSystemDefaultDevice },
    { (const void *)my_all, (const void *)MTLCopyAllDevices },
    { (const void *)my_all_obs, (const void *)MTLCopyAllDevicesWithObserver },
};
