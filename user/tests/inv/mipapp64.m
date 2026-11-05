// SPDX-License-Identifier: MIT
// MipApp: a window whose layers WindowServer composites: a 512 px pattern minified to 48 px with each CA filter
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
static CGImageRef pattern(int n) {
	uint8_t *p = malloc((size_t)n * n * 4);
	for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) { uint8_t *t = p + ((size_t)y * n + x) * 4;
		t[0] = ((x ^ y) & 1) ? 255 : 0; t[1] = ((x >> 3) & 1) ? 255 : 0; t[2] = ((x + y) & 7) == 0 ? 255 : 32; t[3] = 255; }
	CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef c = CGBitmapContextCreate(p, n, n, 8, n * 4, cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
	return CGBitmapContextCreateImage(c);
}
int main(int argc, char **argv) {
	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 600, 400, 200) styleMask:NSWindowStyleMaskBorderless
			backing:NSBackingStoreBuffered defer:NO];
		w.level = NSStatusWindowLevel; w.backgroundColor = NSColor.magentaColor;
		NSView *v = w.contentView; v.wantsLayer = YES;
		CGImageRef img = pattern(512);
		NSArray *f = @[kCAFilterTrilinear, kCAFilterLinear, kCAFilterNearest];
		for (int i = 0; i < 3; i++) {
			CALayer *l = [CALayer layer]; l.frame = CGRectMake(16 + i * 64, 16, 48, 48); l.contents = (__bridge id)img;
			l.minificationFilter = f[i]; [v.layer addSublayer:l];
		}
		// the System Settings icon as the Dock gets it: IconServices' 128 px CGImage, and the NSImage itself, at 64 px trilinear
		NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:@"/System/Applications/System Settings.app"];
		NSRect r = NSMakeRect(0, 0, 128, 128);
		CGImageRef cg = [icon CGImageForProposedRect:&r context:nil hints:nil];
		CALayer *a = [CALayer layer]; a.frame = CGRectMake(16, 100, 64, 64); a.contents = (__bridge id)cg; a.minificationFilter = kCAFilterTrilinear; [v.layer addSublayer:a];
		CALayer *b = [CALayer layer]; b.frame = CGRectMake(96, 100, 64, 64); b.contents = (__bridge id)cg; b.minificationFilter = kCAFilterLinear; [v.layer addSublayer:b];
		CALayer *c2 = [CALayer layer]; c2.frame = CGRectMake(176, 100, 64, 64); c2.contents = (__bridge id)cg; c2.minificationFilter = kCAFilterNearest; [v.layer addSublayer:c2];
		[w orderFrontRegardless];
		[NSTimer scheduledTimerWithTimeInterval:atof(argc > 1 ? argv[1] : "12") repeats:NO block:^(NSTimer *t) { exit(0); }];
		[NSApp run];
	}
	return 0;
}
