// vkshim: a libvulkan.dylib for apps that dlopen the Vulkan loader (ffmpeg on macOS), without the Khronos loader:
// vkGetInstanceProcAddr forwards to the B580 ANV build's vk_icdGetInstanceProcAddr (global and instance commands).
// SPDX-License-Identifier: MIT
//
//   clang -arch x86_64 -dynamiclib -install_name libvulkan.dylib -o libvulkan.dylib vkshim.c
//   run: INTELXE_ANV=/path/to/libvulkan_intel.dylib DYLD_LIBRARY_PATH=<dir of libvulkan.dylib> ffmpeg ...
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void (*vk_fn)(void);
typedef vk_fn (*gipa_fn)(void *instance, const char *name);
static gipa_fn icd;

__attribute__((visibility("default"))) vk_fn vkGetInstanceProcAddr(void *instance, const char *name)
{
	if (!icd) {
		const char *path = getenv("INTELXE_ANV");
		void *lib = dlopen(path ? path : "libvulkan_intel.dylib", RTLD_NOW | RTLD_LOCAL);
		if (lib) icd = (gipa_fn)dlsym(lib, "vk_icdGetInstanceProcAddr");
		if (!icd) { fprintf(stderr, "vkshim: cannot load %s: %s\n", path ? path : "libvulkan_intel.dylib", dlerror()); return NULL; }
	}
	return icd(instance, name);
}
