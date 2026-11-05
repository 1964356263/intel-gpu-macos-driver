// SPDX-License-Identifier: MIT
// vkwin: how much of the BAR window (CPU-visible VRAM) an ANV VkDevice and the Metal plugin's descriptor pools take.
// Reads the window use from debug.intelxe.stats ("used N MB (window W MB)") around each step; WindowServer allocates
// meanwhile, so each step is measured a few times and the smallest change is reported.
//   ./vkwin            device, then the plugin's main descriptor pool (nvmtl_desc_pool_open: 4096 sets of 33 storage
//                      buffers, 128 sampled images, 32 samplers, 128 storage images, 1 dynamic UBO), its bindless heap
//                      (131072 sampled images + 2048 samplers, UPDATE_AFTER_BIND) and a fetch pool, then all destroyed.
// The descriptor types stand in for the plugin's mutable ones (ANV sizes a mutable sampled/storage image or texel
// buffer descriptor as one 64-byte surface state, the same as these). Uses ~100 MB of the window for a moment.
// Test only.   clang -arch x86_64 -O2 -I../../mesa/include -o vkwin vkwin.c
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

static long windowMB(void) {
	char buf[4096];
	size_t l = sizeof(buf);
	if (sysctlbyname("debug.intelxe.stats", buf, &l, NULL, 0)) return -1;
	char *p = strstr(buf, "(window ");
	return p ? strtol(p + 8, NULL, 10) : -1;
}

static PFN_vkGetInstanceProcAddr gipa;
static VkInstance inst;
static VkDevice dev;
#define IP(name) PFN_##name name = (PFN_##name)gipa(inst, #name)

int main(void) {
	void *lib = dlopen("/Library/GPUBundles/nvmtl/libvulkan_intel.dylib", RTLD_NOW | RTLD_LOCAL);
	if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
	gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr");
	if (!gipa) { fprintf(stderr, "no vk_icdGetInstanceProcAddr\n"); return 1; }
	PFN_vkCreateInstance createInstance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
	VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vkwin", 1, NULL, 0, VK_API_VERSION_1_3};
	VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &ai, 0, NULL, 0, NULL};
	long w0 = windowMB();
	if (createInstance(&ici, NULL, &inst)) { fprintf(stderr, "vkCreateInstance\n"); return 1; }
	IP(vkEnumeratePhysicalDevices);
	IP(vkCreateDevice);
	IP(vkGetDeviceProcAddr);
	uint32_t n = 1;
	VkPhysicalDevice pd;
	if (vkEnumeratePhysicalDevices(inst, &n, &pd) || !n) { fprintf(stderr, "no physical device\n"); return 1; }
	float prio = 1;
	VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio};
	VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
	f12.descriptorBindingSampledImageUpdateAfterBind = VK_TRUE;
	f12.descriptorBindingPartiallyBound = VK_TRUE;
	f12.descriptorBindingUpdateUnusedWhilePending = VK_TRUE;
	VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, &f12, 0, 1, &qci, 0, NULL, 0, NULL, NULL};
	long w1 = windowMB();
	if (vkCreateDevice(pd, &dci, NULL, &dev)) { fprintf(stderr, "vkCreateDevice\n"); return 1; }
	usleep(200000);
	long w2 = windowMB();
	printf("window before %ld MB; VkDevice: %+ld MB (instance %+ld)\n", w0, w2 - w1, w1 - w0);
	PFN_vkCreateDescriptorPool createPool = (PFN_vkCreateDescriptorPool)vkGetDeviceProcAddr(dev, "vkCreateDescriptorPool");
	PFN_vkDestroyDescriptorPool destroyPool = (PFN_vkDestroyDescriptorPool)vkGetDeviceProcAddr(dev, "vkDestroyDescriptorPool");
	PFN_vkDestroyDevice destroyDevice = (PFN_vkDestroyDevice)vkGetDeviceProcAddr(dev, "vkDestroyDevice");
	const uint32_t S = 4096;
	VkDescriptorPoolSize mainSizes[5] = {{VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, S}, {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 33 * S},
		{VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 128 * S}, {VK_DESCRIPTOR_TYPE_SAMPLER, 32 * S}, {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 128 * S}};
	VkDescriptorPoolCreateInfo mainCi = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL,
		VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT, S, 5, mainSizes};
	VkDescriptorPoolSize heapSizes[2] = {{VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 131072}, {VK_DESCRIPTOR_TYPE_SAMPLER, 2048}};
	VkDescriptorPoolCreateInfo heapCi = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL,
		VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT, 1, 2, heapSizes};
	VkDescriptorPoolSize fetchSize = {VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 8 * 1024};
	VkDescriptorPoolCreateInfo fetchCi = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL,
		VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT, 1024, 1, &fetchSize};
	struct { const char *name; VkDescriptorPoolCreateInfo *ci; } steps[] = {
		{"main descriptor pool (4096 sets)", &mainCi}, {"bindless heap pool", &heapCi}, {"fetch pool (1024 sets)", &fetchCi}};
	VkDescriptorPool pools[3][3] = {{0}};
	for (int s = 0; s < 3; s++) {
		long best = 1 << 30;
		VkResult r = VK_SUCCESS;
		for (int k = 0; k < 3; k++) {   // three pools of the kind, each measured on its own
			long a = windowMB();
			r = createPool(dev, steps[s].ci, NULL, &pools[s][k]);
			long b = windowMB();
			if (r) break;
			if (b - a < best) best = b - a;
		}
		if (r) printf("%s: vkCreateDescriptorPool -> %d\n", steps[s].name, r);
		else printf("%s: %+ld MB each (smallest of 3)\n", steps[s].name, best);
	}
	long w3 = windowMB();
	for (int s = 0; s < 3; s++)
		for (int k = 0; k < 3; k++)
			if (pools[s][k]) destroyPool(dev, pools[s][k], NULL);
	usleep(100000);
	long w4 = windowMB();
	destroyDevice(dev, NULL);
	usleep(200000);
	long w5 = windowMB();
	printf("all pools %ld MB -> destroyed %ld MB -> device destroyed %ld MB (started at %ld)\n", w3, w4, w5, w0);
	return 0;
}
