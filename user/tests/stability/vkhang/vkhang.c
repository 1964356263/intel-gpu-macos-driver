// vkhang: fault injection for the B580 hang recovery (job watchdog, GuC engine reset, ban, VK_ERROR_DEVICE_LOST).
// Loads Mesa's ANV directly (no loader), creates a device on one queue family and dispatches spin.comp, a compute
// shader that loops until the host writes a stop flag into a host-coherent buffer. Then it waits on the fence and
// reports how the wait ended (success, timeout, device lost) and what a second submit on the same queue returns.
// SPDX-License-Identifier: MIT
//
//   build: ./build.sh
//   run:   vkhang [--family compute|render] [--iters N] [--release-ms N] [--wait-s S] [--icd path/to/libvulkan_intel.dylib]
//
//   --iters N       the shader stops by itself after N loop iterations: a bounded job, never a hang (the only stop
//                   that is certain: the host's flag below may sit unseen behind the GPU's L3). 0 (default) = no bound.
//   --release-ms N  the host also writes the stop flag after N ms (best effort, see --iters). With --iters 0 and
//                   --release-ms 0 the job is a real hang that only the kernel can end (watchdog / GuC reset / ban).
//   --wait-s S      how long to wait on the fence (default 30). Still not signaled after that: the host writes the
//                   stop flag (rescue) and waits 5 s more.
// Exit code: 0 fence signaled and the next submit worked, 2 the device was lost (the expected end of a hang),
// 3 the fence timed out, 1 a setup error.

#include <dlfcn.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <vulkan/vulkan.h>

#include "spin_spv.h"

static PFN_vkGetInstanceProcAddr gipa;

#define CHECK(call)                                                             \
	do {                                                                    \
		VkResult r_ = (call);                                           \
		if (r_ != VK_SUCCESS) {                                         \
			printf("%s -> VkResult %d\n", #call, r_);               \
			exit(1);                                                \
		}                                                               \
	} while (0)
#define IFN(name) PFN_##name name = (PFN_##name)gipa(instance, #name)
#define DFN(name) PFN_##name name = (PFN_##name)vkGetDeviceProcAddr(device, #name)

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const char *res_name(VkResult r)
{
	switch (r) {
	case VK_SUCCESS: return "VK_SUCCESS";
	case VK_TIMEOUT: return "VK_TIMEOUT";
	case VK_ERROR_DEVICE_LOST: return "VK_ERROR_DEVICE_LOST";
	case VK_ERROR_OUT_OF_HOST_MEMORY: return "VK_ERROR_OUT_OF_HOST_MEMORY";
	case VK_ERROR_OUT_OF_DEVICE_MEMORY: return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
	default: return "other";
	}
}

int main(int argc, char **argv)
{
	const char *icd = "/Library/GPUBundles/nvmtl/libvulkan_intel.dylib", *family = "compute";
	int release_ms = 0, wait_s = 30;
	uint32_t max_iter = 0;
	for (int i = 1; i + 1 < argc; i += 2) {
		if (!strcmp(argv[i], "--family")) family = argv[i + 1];
		else if (!strcmp(argv[i], "--release-ms")) release_ms = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--iters")) max_iter = (uint32_t)strtoul(argv[i + 1], NULL, 0);
		else if (!strcmp(argv[i], "--wait-s")) wait_s = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--icd")) icd = argv[i + 1];
		else {
			printf("unknown option %s\n", argv[i]);
			return 1;
		}
	}
	setvbuf(stdout, NULL, _IONBF, 0);
	void *lib = dlopen(icd, RTLD_NOW | RTLD_LOCAL);
	if (!lib || !(gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr"))) {
		printf("cannot load %s: %s\n", icd, dlerror());
		return 1;
	}
	VkInstance instance = VK_NULL_HANDLE;
	IFN(vkCreateInstance);
	VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vkhang",
		.apiVersion = VK_API_VERSION_1_2};
	VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
	CHECK(vkCreateInstance(&ici, NULL, &instance));
	IFN(vkEnumeratePhysicalDevices);
	IFN(vkGetPhysicalDeviceQueueFamilyProperties);
	IFN(vkGetPhysicalDeviceMemoryProperties);
	IFN(vkCreateDevice);
	IFN(vkGetDeviceProcAddr);
	uint32_t n = 1;
	VkPhysicalDevice pd;
	CHECK(vkEnumeratePhysicalDevices(instance, &n, &pd));
	VkQueueFamilyProperties qf[16];
	uint32_t nq = 16, fam = ~0u;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qf);
	for (uint32_t i = 0; i < nq && fam == ~0u; i++) {
		const VkQueueFlags f = qf[i].queueFlags;
		if (!strcmp(family, "render") ? (f & VK_QUEUE_GRAPHICS_BIT) != 0
					      : (f & VK_QUEUE_COMPUTE_BIT) && !(f & VK_QUEUE_GRAPHICS_BIT))
			fam = i;
	}
	if (fam == ~0u) {
		printf("no %s queue family\n", family);
		return 1;
	}
	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = fam,
		.queueCount = 1, .pQueuePriorities = &prio};
	VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci};
	VkDevice device;
	CHECK(vkCreateDevice(pd, &dci, NULL, &device));
	DFN(vkGetDeviceQueue);
	DFN(vkCreateBuffer);
	DFN(vkGetBufferMemoryRequirements);
	DFN(vkAllocateMemory);
	DFN(vkBindBufferMemory);
	DFN(vkMapMemory);
	DFN(vkCreateShaderModule);
	DFN(vkCreateDescriptorSetLayout);
	DFN(vkCreatePipelineLayout);
	DFN(vkCreateComputePipelines);
	DFN(vkCreateDescriptorPool);
	DFN(vkAllocateDescriptorSets);
	DFN(vkUpdateDescriptorSets);
	DFN(vkCreateCommandPool);
	DFN(vkAllocateCommandBuffers);
	DFN(vkBeginCommandBuffer);
	DFN(vkCmdBindPipeline);
	DFN(vkCmdBindDescriptorSets);
	DFN(vkCmdDispatch);
	DFN(vkCmdPushConstants);
	DFN(vkEndCommandBuffer);
	DFN(vkCreateFence);
	DFN(vkResetFences);
	DFN(vkQueueSubmit);
	DFN(vkWaitForFences);
	DFN(vkDestroyDevice);
	VkQueue queue;
	vkGetDeviceQueue(device, fam, 0, &queue);

	VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 4096,
		.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT};
	VkBuffer buf;
	CHECK(vkCreateBuffer(device, &bci, NULL, &buf));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(device, buf, &mr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	uint32_t type = ~0u;
	for (uint32_t i = 0; i < mp.memoryTypeCount && type == ~0u; i++)
		if ((mr.memoryTypeBits & 1u << i) && (mp.memoryTypes[i].propertyFlags & want) == want) type = i;
	if (type == ~0u) {
		printf("no host-coherent memory type\n");
		return 1;
	}
	VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
		.memoryTypeIndex = type};
	VkDeviceMemory mem;
	CHECK(vkAllocateMemory(device, &mai, NULL, &mem));
	CHECK(vkBindBufferMemory(device, buf, mem, 0));
	volatile uint32_t *flag;
	CHECK(vkMapMemory(device, mem, 0, 4096, 0, (void **)&flag));
	flag[0] = flag[1] = flag[2] = 0;

	VkShaderModuleCreateInfo smci = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = spin_spv_len,
		.pCode = (const uint32_t *)spin_spv};
	VkShaderModule sm;
	CHECK(vkCreateShaderModule(device, &smci, NULL, &sm));
	VkDescriptorSetLayoutBinding b0 = {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT};
	VkDescriptorSetLayoutCreateInfo dslci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = 1, .pBindings = &b0};
	VkDescriptorSetLayout dsl;
	CHECK(vkCreateDescriptorSetLayout(device, &dslci, NULL, &dsl));
	VkPushConstantRange pcr = {VK_SHADER_STAGE_COMPUTE_BIT, 0, 4};
	VkPipelineLayoutCreateInfo plci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1,
		.pSetLayouts = &dsl, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr};
	VkPipelineLayout pl;
	CHECK(vkCreatePipelineLayout(device, &plci, NULL, &pl));
	VkComputePipelineCreateInfo cpci = {.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
			.module = sm, .pName = "main"},
		.layout = pl};
	VkPipeline pipe;
	CHECK(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));
	VkDescriptorPoolSize ps = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1};
	VkDescriptorPoolCreateInfo dpci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
		.poolSizeCount = 1, .pPoolSizes = &ps};
	VkDescriptorPool dp;
	CHECK(vkCreateDescriptorPool(device, &dpci, NULL, &dp));
	VkDescriptorSetAllocateInfo dsai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp,
		.descriptorSetCount = 1, .pSetLayouts = &dsl};
	VkDescriptorSet ds;
	CHECK(vkAllocateDescriptorSets(device, &dsai, &ds));
	VkDescriptorBufferInfo dbi = {buf, 0, 4096};
	VkWriteDescriptorSet w = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .descriptorCount = 1,
		.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi};
	vkUpdateDescriptorSets(device, 1, &w, 0, NULL);
	VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = fam};
	VkCommandPool pool;
	CHECK(vkCreateCommandPool(device, &cpi, NULL, &pool));
	VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 2};
	VkCommandBuffer cbs[2], cb;
	CHECK(vkAllocateCommandBuffers(device, &cbai, cbs));
	// cbs[0] the spin, cbs[1] the follow-up: the same shader bounded to one iteration, so it never hangs
	const uint32_t bounds[2] = {max_iter, 1};
	for (int i = 0; i < 2; i++) {
		VkCommandBufferBeginInfo cbbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
		CHECK(vkBeginCommandBuffer(cbs[i], &cbbi));
		vkCmdBindPipeline(cbs[i], VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
		vkCmdBindDescriptorSets(cbs[i], VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, NULL);
		vkCmdPushConstants(cbs[i], pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, 4, &bounds[i]);
		vkCmdDispatch(cbs[i], 1, 1, 1);
		CHECK(vkEndCommandBuffer(cbs[i]));
	}
	cb = cbs[0];
	VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence fence;
	CHECK(vkCreateFence(device, &fci, NULL, &fence));

	printf("family %u (%s), iteration bound %u, release after %d ms, fence wait %d s%s\n", fam, family, max_iter,
		release_ms, wait_s, max_iter || release_ms ? "" : " - A REAL HANG");
	VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
	const double t0 = now_s();
	CHECK(vkQueueSubmit(queue, 1, &si, fence));
	while (!flag[2] && now_s() - t0 < 3) usleep(1000);
	printf("shader %s after %.3f s\n", flag[2] ? "started" : "NOT started", now_s() - t0);
	if (release_ms) {
		while ((now_s() - t0) * 1000 < release_ms) usleep(1000);
		flag[0] = 1;
		printf("stop flag written at %.3f s (iterations so far %u)\n", now_s() - t0, flag[1]);
	}
	VkResult r = VK_TIMEOUT;
	for (int s = 0; s < wait_s && r == VK_TIMEOUT; s++) {
		r = vkWaitForFences(device, 1, &fence, VK_TRUE, 1000000000ull);
		printf("  %.1f s: %s, iterations %u\n", now_s() - t0, res_name(r), flag[1]);
	}
	const double tf = now_s() - t0;
	int rc;
	if (r == VK_TIMEOUT) {
		flag[0] = 1;   // rescue: let the shader end by itself
		r = vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ull);
		printf("fence still unsignaled after %.1f s: stop flag written, then %s\n", tf, res_name(r));
		rc = 3;
	} else {
		printf("fence wait ended after %.3f s: %s\n", tf, res_name(r));
		// what the queue does now: a lost device (banned queue) refuses the submit
		vkResetFences(device, 1, &fence);
		flag[0] = 1;
		si.pCommandBuffers = &cbs[1];
		VkResult r2 = vkQueueSubmit(queue, 1, &si, fence);
		VkResult r3 = r2 == VK_SUCCESS ? vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ull) : r2;
		printf("second submit: %s, its fence: %s\n", res_name(r2), res_name(r3));
		rc = r == VK_ERROR_DEVICE_LOST || r2 == VK_ERROR_DEVICE_LOST || r3 == VK_ERROR_DEVICE_LOST ? 2 : 0;
	}
	vkDestroyDevice(device, NULL);   // resources go with the process
	printf("done rc %d\n", rc);
	return rc;
}
