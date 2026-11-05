// vk_smoke: loads Mesa's libvulkan_intel.dylib directly (no Vulkan loader) and runs the smallest Vulkan flow on the
// B580: instance, physical device, device, host-visible memory, a buffer, an empty command buffer submitted with a fence.
// SPDX-License-Identifier: MIT
//
//   build: tests/build.sh
//   run:   XEMAC_FAKE=1 [XEMAC_TRACE=1] tests/vk_smoke [path/to/libvulkan_intel.dylib [queue family]]

#include <dlfcn.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>

static PFN_vkGetInstanceProcAddr gipa;

#define CHECK(call)                                                                       \
	do {                                                                              \
		VkResult r_ = (call);                                                     \
		printf("%-60s %s\n", #call, r_ == VK_SUCCESS ? "ok" : "FAILED");          \
		if (r_ != VK_SUCCESS) {                                                   \
			printf("  -> VkResult %d\n", r_);                                 \
			exit(1);                                                          \
		}                                                                         \
	} while (0)

#define IFN(name) PFN_##name name = (PFN_##name)gipa(instance, #name)
#define DFN(name) PFN_##name name = (PFN_##name)vkGetDeviceProcAddr(device, #name)

static const char *heap_flags(VkMemoryHeapFlags f)
{
	return f & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT ? "DEVICE_LOCAL" : "-";
}

static void type_flags(VkMemoryPropertyFlags f, char *buf)
{
	buf[0] = 0;
	if (f & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) strcat(buf, "DEVICE_LOCAL ");
	if (f & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) strcat(buf, "HOST_VISIBLE ");
	if (f & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) strcat(buf, "HOST_COHERENT ");
	if (f & VK_MEMORY_PROPERTY_HOST_CACHED_BIT) strcat(buf, "HOST_CACHED ");
	if (!buf[0]) strcat(buf, "-");
}

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "../../../mesa/build/src/intel/vulkan/libvulkan_intel.dylib";
	void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		printf("dlopen: %s\n", dlerror());
		return 1;
	}
	gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr");
	if (!gipa) {
		printf("no vk_icdGetInstanceProcAddr\n");
		return 1;
	}
	VkInstance instance = VK_NULL_HANDLE;
	IFN(vkCreateInstance);
	IFN(vkEnumerateInstanceVersion);
	uint32_t api = 0;
	vkEnumerateInstanceVersion(&api);
	printf("ICD instance version %u.%u.%u\n", VK_VERSION_MAJOR(api), VK_VERSION_MINOR(api), VK_VERSION_PATCH(api));

	VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vk_smoke",
				 .apiVersion = VK_API_VERSION_1_3};
	VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
	CHECK(vkCreateInstance(&ici, NULL, &instance));

	IFN(vkEnumeratePhysicalDevices);
	IFN(vkGetPhysicalDeviceProperties);
	IFN(vkGetPhysicalDeviceMemoryProperties);
	IFN(vkGetPhysicalDeviceQueueFamilyProperties);
	IFN(vkCreateDevice);
	IFN(vkGetDeviceProcAddr);
	IFN(vkDestroyInstance);

	uint32_t n = 0;
	CHECK(vkEnumeratePhysicalDevices(instance, &n, NULL));
	printf("physical devices: %u\n", n);
	if (!n)
		return 1;
	VkPhysicalDevice pd;
	n = 1;
	CHECK(vkEnumeratePhysicalDevices(instance, &n, &pd));

	VkPhysicalDeviceProperties p;
	vkGetPhysicalDeviceProperties(pd, &p);
	printf("  name        %s\n  ids         %04x:%04x type %d\n  api         %u.%u.%u driver 0x%x\n",
	       p.deviceName, p.vendorID, p.deviceID, p.deviceType, VK_VERSION_MAJOR(p.apiVersion),
	       VK_VERSION_MINOR(p.apiVersion), VK_VERSION_PATCH(p.apiVersion), p.driverVersion);
	printf("  limits      maxImageDimension2D %u, maxComputeWorkGroupInvocations %u, timestampPeriod %.3f ns\n",
	       p.limits.maxImageDimension2D, p.limits.maxComputeWorkGroupInvocations, p.limits.timestampPeriod);

	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	for (uint32_t i = 0; i < mp.memoryHeapCount; i++)
		printf("  heap %u      %" PRIu64 " MB %s\n", i, mp.memoryHeaps[i].size >> 20,
		       heap_flags(mp.memoryHeaps[i].flags));
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++) {
		char buf[96];
		type_flags(mp.memoryTypes[i].propertyFlags, buf);
		printf("  type %u      heap %u %s\n", i, mp.memoryTypes[i].heapIndex, buf);
	}

	VkQueueFamilyProperties qf[8];
	n = 8;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, qf);
	for (uint32_t i = 0; i < n; i++)
		printf("  queue fam %u flags 0x%x count %u timestampValidBits %u\n", i, qf[i].queueFlags,
		       qf[i].queueCount, qf[i].timestampValidBits);

	uint32_t family = argc > 2 ? atoi(argv[2]) : 0;
	printf("using queue family %u\n", family);
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family,
				       .queueCount = 1, .pQueuePriorities = &prio};
	VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
				  .pQueueCreateInfos = &qci};
	VkDevice device;
	CHECK(vkCreateDevice(pd, &dci, NULL, &device));

	DFN(vkGetDeviceQueue);
	DFN(vkAllocateMemory);
	DFN(vkMapMemory);
	DFN(vkUnmapMemory);
	DFN(vkFreeMemory);
	DFN(vkCreateBuffer);
	DFN(vkGetBufferMemoryRequirements);
	DFN(vkBindBufferMemory);
	DFN(vkDestroyBuffer);
	DFN(vkCreateCommandPool);
	DFN(vkAllocateCommandBuffers);
	DFN(vkBeginCommandBuffer);
	DFN(vkEndCommandBuffer);
	DFN(vkCmdFillBuffer);
	DFN(vkResetFences);
	DFN(vkCreateFence);
	DFN(vkQueueSubmit);
	DFN(vkWaitForFences);
	DFN(vkGetFenceStatus);
	DFN(vkDestroyFence);
	DFN(vkDestroyCommandPool);
	DFN(vkDeviceWaitIdle);
	DFN(vkDestroyDevice);

	VkQueue queue;
	vkGetDeviceQueue(device, family, 0, &queue);

	uint32_t host_type = UINT32_MAX;
	for (uint32_t i = 0; i < mp.memoryTypeCount && host_type == UINT32_MAX; i++)
		if (mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
			host_type = i;
	VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = 1 << 20,
				    .memoryTypeIndex = host_type};
	VkDeviceMemory mem;
	CHECK(vkAllocateMemory(device, &mai, NULL, &mem));
	uint32_t *map;
	CHECK(vkMapMemory(device, mem, 0, VK_WHOLE_SIZE, 0, (void **)&map));
	for (uint32_t i = 0; i < (1 << 18); i++)
		map[i] = i * 2654435761u;
	uint32_t bad = 0;
	for (uint32_t i = 0; i < (1 << 18); i++)
		bad += map[i] != i * 2654435761u;
	printf("  mapped 1 MB of memory type %u at %p, pattern check: %s\n", host_type, (void *)map,
	       bad ? "MISMATCH" : "ok");
	vkUnmapMemory(device, mem);

	VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 65536,
				  .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT};
	VkBuffer buf;
	CHECK(vkCreateBuffer(device, &bci, NULL, &buf));
	VkMemoryRequirements req;
	vkGetBufferMemoryRequirements(device, buf, &req);
	printf("  buffer requirements: size %" PRIu64 " alignment %" PRIu64 " types 0x%x\n", req.size, req.alignment,
	       req.memoryTypeBits);
	CHECK(vkBindBufferMemory(device, buf, mem, 0));

	VkCommandPoolCreateInfo cpci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family};
	VkCommandPool pool;
	CHECK(vkCreateCommandPool(device, &cpci, NULL, &pool));
	VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
					    .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
	VkCommandBuffer cb;
	CHECK(vkAllocateCommandBuffers(device, &cbai, &cb));
	VkCommandBufferBeginInfo cbbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
	CHECK(vkBeginCommandBuffer(cb, &cbbi));
	CHECK(vkEndCommandBuffer(cb));

	VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence;
	CHECK(vkCreateFence(device, &fci, NULL, &fence));
	VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
	CHECK(vkQueueSubmit(queue, 1, &si, fence));
	CHECK(vkWaitForFences(device, 1, &fence, VK_TRUE, 1000000000ull));
	CHECK(vkGetFenceStatus(device, fence));
	CHECK(vkDeviceWaitIdle(device));

	// Second submission with real work: vkCmdFillBuffer goes through blorp and the shader compiler (or MI commands).
	// The fake device does not execute batches, so the buffer contents are not checked.
	VkCommandBuffer cb2;
	CHECK(vkAllocateCommandBuffers(device, &cbai, &cb2));
	CHECK(vkBeginCommandBuffer(cb2, &cbbi));
	vkCmdFillBuffer(cb2, buf, 0, 65536, 0xdeadbeef);
	CHECK(vkEndCommandBuffer(cb2));
	CHECK(vkResetFences(device, 1, &fence));
	si.pCommandBuffers = &cb2;
	CHECK(vkQueueSubmit(queue, 1, &si, fence));
	CHECK(vkWaitForFences(device, 1, &fence, VK_TRUE, 1000000000ull));
	if (!getenv("XEMAC_FAKE")) {
		CHECK(vkMapMemory(device, mem, 0, VK_WHOLE_SIZE, 0, (void **)&map));   // the first map was released above
		uint32_t good = 0;
		for (uint32_t i = 0; i < 65536 / 4; i++) good += ((volatile uint32_t *)map)[i] == 0xdeadbeef;
		printf("  vkCmdFillBuffer result: %u/16384 dwords are 0xdeadbeef -> %s\n", good,
			good == 16384 ? "THE GPU EXECUTED VULKAN WORK" : "not written");
	}

	vkDestroyFence(device, fence, NULL);
	vkDestroyCommandPool(device, pool, NULL);
	vkDestroyBuffer(device, buf, NULL);
	vkFreeMemory(device, mem, NULL);
	vkDestroyDevice(device, NULL);
	vkDestroyInstance(instance, NULL);
	printf("done\n");
	return 0;
}
