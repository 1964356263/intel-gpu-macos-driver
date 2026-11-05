// SPDX-License-Identifier: MIT
// encreg.dylib: DYLD_INSERT_LIBRARIES test shim - loads the encoder binary in $INTELXEVENC_LIB and calls its
// IntelXeVEnc_Register (HEVC, H.264, AV1 with the IntelXe IDs), without Metal, so the installed one stays out
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void encreg(void) {
	const char *lib = getenv("INTELXEVENC_LIB");
	void *h = lib ? dlopen(lib, RTLD_NOW | RTLD_LOCAL) : NULL;
	int (*reg)(void) = h ? (int (*)(void))dlsym(h, "IntelXeVEnc_Register") : NULL;
	fprintf(stderr, "encreg: %s -> %d\n", lib ? lib : "(INTELXEVENC_LIB unset)", reg ? reg() : -1);
}
