// SPDX-License-Identifier: MIT
// sbprobe: what a decoder in a sandboxed video service can reach: NMXAccel's 'B580' client, and ANV (vkCreateInstance,
// physical devices, the video queue family).
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdio.h>
#include <vulkan/vulkan.h>
int main(void) {
	io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NMXAccel"));
	io_connect_t c = 0;
	kern_return_t kr = s ? IOServiceOpen(s, mach_task_self(), 0x42353830u, &c) : -1;
	printf("NMXAccel %s, IOServiceOpen('B580') -> 0x%x\n", s ? "found" : "not found", kr);
	if (c) IOServiceClose(c);
	void *h = dlopen("/Library/GPUBundles/nvmtl/libvulkan_intel.dylib", RTLD_NOW | RTLD_LOCAL);
	PFN_vkGetInstanceProcAddr gipa = h ? (PFN_vkGetInstanceProcAddr)dlsym(h, "vk_icdGetInstanceProcAddr") : NULL;
	printf("ANV %s\n", gipa ? "loaded" : dlerror());
	if (!gipa) return 1;
	PFN_vkCreateInstance ci = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
	VkApplicationInfo ai = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "sbprobe", 1, NULL, 0, VK_API_VERSION_1_3 };
	VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &ai };
	VkInstance inst; VkResult r = ci(&ici, NULL, &inst);
	printf("vkCreateInstance -> %d\n", r);
	if (r) return 1;
	PFN_vkEnumeratePhysicalDevices ep = (PFN_vkEnumeratePhysicalDevices)gipa(inst, "vkEnumeratePhysicalDevices");
	uint32_t n = 4; VkPhysicalDevice pd[4]; r = ep(inst, &n, pd);
	printf("physical devices: %u (%d)\n", n, r);
	if (n) { PFN_vkGetPhysicalDeviceQueueFamilyProperties q = (PFN_vkGetPhysicalDeviceQueueFamilyProperties)gipa(inst, "vkGetPhysicalDeviceQueueFamilyProperties");
		uint32_t nq = 8; VkQueueFamilyProperties qp[8]; q(pd[0], &nq, qp);
		for (uint32_t i = 0; i < nq; i++) printf("  family %u flags 0x%x x%u\n", i, qp[i].queueFlags, qp[i].queueCount); }
	return 0;
}
