// SPDX-License-Identifier: MIT
// present: minimal CAMetalLayer present loop (clear + present), to see whether presentation is paced by the display.
//   ./present [-t sec] [-w W] [-h H] [-n maxDrawableCount] [-sync 0|1] [-nopresent] [-wait]
// displaySyncEnabled = NO (default here) lets presents run past the refresh rate on a real Mac. NVMTL_BUNDLE=<bundle>
// loads a staged plugin build (layer.device is that device). Prints fps per second and, at the end, where the time went:
// nextDrawable (waiting for a free drawable), encode+commit, and the wait for the GPU when -wait is given.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOKit/IOKitLib.h>
#import <objc/message.h>
#include <mach/mach_time.h>

static double now_s(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9; }
static id<MTLDevice> bundleDevice(const char *path) {
    NSBundle *b = [NSBundle bundleWithPath:@(path)]; NSError *e = nil;
    if (![b loadAndReturnError:&e]) { printf("bundle %s: %s\n", path, e.localizedDescription.UTF8String); return nil; }
    Class cls = [b classNamed:@"NVMTLDevice"]; if (!cls) return nil;
    io_iterator_t it = 0; id<MTLDevice> dev = nil;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS) return nil;
    for (io_service_t svc; !dev && (svc = IOIteratorNext(it)); IOObjectRelease(svc)) {
        CFTypeRef name = IORegistryEntryCreateCFProperty(svc, CFSTR("MetalPluginClassName"), kCFAllocatorDefault, 0);
        if (name && CFEqual(name, CFSTR("NVMTLDevice")))
            dev = ((id (*)(id, SEL, mach_port_t))objc_msgSend)([cls alloc], sel_registerName("initWithAcceleratorPort:"), svc);
        if (name) CFRelease(name);
    }
    IOObjectRelease(it);
    return dev;
}
int main(int argc, char **argv) { @autoreleasepool {
    double T = 6; int W = 1920, H = 1080, N = 3, sync = 0, present = 1, wait = 0, fs = 0, vis = 0; double px = 40, py = 40;
    for (int a = 1; a < argc; a++) {
        if (!strcmp(argv[a], "-t") && a + 1 < argc) T = atof(argv[++a]);
        else if (!strcmp(argv[a], "-w") && a + 1 < argc) W = atoi(argv[++a]);
        else if (!strcmp(argv[a], "-h") && a + 1 < argc) H = atoi(argv[++a]);
        else if (!strcmp(argv[a], "-n") && a + 1 < argc) N = atoi(argv[++a]);
        else if (!strcmp(argv[a], "-sync") && a + 1 < argc) sync = atoi(argv[++a]);
        else if (!strcmp(argv[a], "-nopresent")) present = 0;
        else if (!strcmp(argv[a], "-wait")) wait = 1;
        else if (!strcmp(argv[a], "-fs")) fs = 1;
        else if (!strcmp(argv[a], "-alpha0")) vis = 1;
        else if (!strcmp(argv[a], "-mini")) vis = 2;
        else if (!strcmp(argv[a], "-orderout")) vis = 3;
        else if (!strcmp(argv[a], "-behind")) vis = 4;
        else if (!strcmp(argv[a], "-pos") && a + 2 < argc) { px = atof(argv[++a]); py = atof(argv[++a]); }
    }
    const char *bp = getenv("NVMTL_BUNDLE");
    id<MTLDevice> dev = bp ? bundleDevice(bp) : MTLCreateSystemDefaultDevice();
    if (!dev) { printf("no device\n"); return 2; }
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp finishLaunching];
    NSScreen *scr = [NSScreen mainScreen];
    NSRect fr = fs ? scr.frame : NSMakeRect(px, py, W / scr.backingScaleFactor, H / scr.backingScaleFactor);
    if (fs) { W = (int)(fr.size.width * scr.backingScaleFactor); H = (int)(fr.size.height * scr.backingScaleFactor); }
    NSWindow *win = [[NSWindow alloc] initWithContentRect:fr styleMask:fs ? NSWindowStyleMaskBorderless : NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    if (fs) win.level = NSMainMenuWindowLevel + 1;
    win.title = @"present"; win.releasedWhenClosed = NO;
    CAMetalLayer *L = [CAMetalLayer layer];
    L.device = dev; L.pixelFormat = MTLPixelFormatBGRA8Unorm; L.framebufferOnly = YES;
    L.displaySyncEnabled = sync; L.maximumDrawableCount = (NSUInteger)N; L.drawableSize = CGSizeMake(W, H);
    win.contentView.wantsLayer = YES; win.contentView.layer = L;
    [win makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    if (vis == 1) win.alphaValue = 0; else if (vis == 2) [win miniaturize:nil]; else if (vis == 3) [win orderOut:nil]; else if (vis == 4) [win orderBack:nil];
    printf("window state %d\n", vis);
    double refresh = 0; if (@available(macOS 12.0, *)) refresh = scr.maximumFramesPerSecond;
    printf("device %s (%s) | %dx%d drawables %d displaySync %d present %d wait %d fs %d | screen %.0f Hz scale %.0f\n", dev.name.UTF8String,
           NSStringFromClass([dev class]).UTF8String, W, H, N, sync, present, wait, fs, refresh, scr.backingScaleFactor);
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLTexture> off = present ? nil : [dev newTextureWithDescriptor:({ MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO]; d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate; d; })];
    double t0 = now_s(), last = t0, tNext = 0, tEnc = 0, tWait = 0, nextMax = 0; long n = 0, nl = 0, nilDrawables = 0;
    while (now_s() - t0 < T) @autoreleasepool {
        NSEvent *ev; while ((ev = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:ev];
        double a = now_s();
        id<CAMetalDrawable> dr = present ? [L nextDrawable] : nil;
        double b = now_s(); tNext += b - a; if (b - a > nextMax) nextMax = b - a;
        if (present && !dr) { nilDrawables++; continue; }
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = present ? dr.texture : off; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake((n % 120) / 120.0, 0.3, 0.6, 1);
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        if (present) [cb presentDrawable:dr];
        [cb commit];
        double c = now_s(); tEnc += c - b;
        if (wait) { [cb waitUntilCompleted]; tWait += now_s() - c; }
        n++; nl++;
        if (c - last >= 1.0) { printf("  %.0f fps\n", nl / (c - last)); fflush(stdout); last = c; nl = 0; }
    }
    double el = now_s() - t0;
    printf("total %ld frames in %.2f s = %.0f fps | per frame: nextDrawable %.0f us (max %.1f ms), encode+commit %.0f us, gpu wait %.0f us | nil drawables %ld\n",
           n, el, n / el, tNext / n * 1e6, nextMax * 1e3, tEnc / n * 1e6, wait ? tWait / n * 1e6 : 0, nilDrawables);
    [win orderOut:nil];
} return 0; }
