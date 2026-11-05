// SPDX-License-Identifier: MIT
// dmode: list the main display's modes, or switch to WxH (IntelXeFB scaled-mode test, run in the console session).
//   clang -arch x86_64 -mmacosx-version-min=15.0 -O1 -o dmode dmode.c -framework CoreGraphics -framework CoreFoundation
//   ./dmode            list
//   ./dmode 1920 1080  switch (first mode of that size)
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
	CGDirectDisplayID d = CGMainDisplayID();
	CFStringRef k = kCGDisplayShowDuplicateLowResolutionModes;
	CFDictionaryRef opt = CFDictionaryCreate(NULL, (const void **)&k, (const void **)&kCFBooleanTrue, 1,
	                                         &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, opt);
	CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
	if (!modes || !cur) { fprintf(stderr, "no display modes (not in the console session?)\n"); return 1; }
	printf("display 0x%x current %zux%zu (pixels %zux%zu) %.2f Hz\n", d, CGDisplayModeGetWidth(cur), CGDisplayModeGetHeight(cur),
	       CGDisplayModeGetPixelWidth(cur), CGDisplayModeGetPixelHeight(cur), CGDisplayModeGetRefreshRate(cur));
	size_t want_w = argc > 2 ? (size_t)atoi(argv[1]) : 0, want_h = argc > 2 ? (size_t)atoi(argv[2]) : 0;
	for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
		CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
		size_t w = CGDisplayModeGetWidth(m), h = CGDisplayModeGetHeight(m);
		if (!want_w)
			printf("  %zux%zu pixels %zux%zu %.2f Hz io %d%s\n", w, h, CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
			       CGDisplayModeGetRefreshRate(m), CGDisplayModeGetIODisplayModeID(m), CGDisplayModeIsUsableForDesktopGUI(m) ? "" : " (not for GUI)");
		else if (w == want_w && h == want_h && CGDisplayModeGetPixelWidth(m) == w) {
			CGError e = CGDisplaySetDisplayMode(d, m, NULL);
			printf("set %zux%zu (io %d): %d\n", w, h, CGDisplayModeGetIODisplayModeID(m), e);
			return e != kCGErrorSuccess;
		}
	}
	if (want_w) { printf("no %zux%zu mode\n", want_w, want_h); return 1; }
	return 0;
}
