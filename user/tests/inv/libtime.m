// SPDX-License-Identifier: MIT
// libtime <metallib> [n] [gap_ms]: load a library, wait gap_ms (the app doing other start-up work), then make n of its
// functions one after the other, as an app creating its pipelines; prints the time spent in newFunctionWithName.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "pickdev.h"
#include <mach/mach_time.h>
static double ms(uint64_t a, uint64_t b) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return (double)(b - a) * tb.numer / tb.denom / 1e6; }
int main(int argc, char **argv) { @autoreleasepool {
	if (argc < 2) { printf("usage: libtime <metallib> [n] [gap_ms]\n"); return 2; }
	const int n = argc > 2 ? atoi(argv[2]) : 64, gap = argc > 3 ? atoi(argv[3]) : 0;
	id<MTLDevice> dev = mtl_pick_intelxe();
	NSError *e = nil; const uint64_t t0 = mach_absolute_time();
	id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e];
	const uint64_t t1 = mach_absolute_time();
	if (!lib) { printf("no library: %s\n", e.localizedDescription.UTF8String); return 1; }
	NSArray<NSString *> *names = [lib.functionNames sortedArrayUsingSelector:@selector(compare:)];
	if (gap) usleep((useconds_t)gap * 1000);
	const uint64_t t2 = mach_absolute_time(); int made = 0;
	for (NSString *name in names) { if (made >= n) break; if ([lib newFunctionWithName:name]) made++; }
	const uint64_t t3 = mach_absolute_time();
	printf("library %.1f ms (%lu functions), %d functions made in %.1f ms after a %d ms gap\n", ms(t0, t1), (unsigned long)names.count, made, ms(t2, t3), gap);
	return 0; } }
