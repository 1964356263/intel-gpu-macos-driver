// SPDX-License-Identifier: MIT
// metalpre.dylib: DYLD_INSERT_LIBRARIES test shim - brings Metal up at load, so the GPU plug-in registers the B580
// codecs before the tool asks VideoToolbox for one (as in any app with a Metal view)
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void metalpre(void) {
	NSArray *d = MTLCopyAllDevices();
	if (getenv("METALPRE_VERBOSE")) fprintf(stderr, "metalpre: %lu Metal devices\n", (unsigned long)d.count);
}
