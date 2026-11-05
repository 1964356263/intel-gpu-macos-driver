// vk_compute: an ordinary Vulkan app linked against the Khronos loader (libvulkan.1.dylib), no driver path anywhere.
// Instance (no portability enumeration), every physical device the loader reports, then on the first discrete GPU
// (or argv[1] index): device + compute queue, a host-visible storage buffer, a compute dispatch writing
// data[i] = i*3 + 7 over N uints, fence wait, check on the CPU.
// SPDX-License-Identifier: MIT
//   clang -arch x86_64 -mmacosx-version-min=15.0 -I<headers> vk_compute.c -L<loader lib> -lvulkan -Wl,-rpath,/usr/local/lib
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define CHECK(call)                                                                          \
	do {                                                                                 \
		VkResult r_ = (call);                                                        \
		if (r_ != VK_SUCCESS) { printf("%s -> VkResult %d\nFAIL\n", #call, r_); exit(1); } \
	} while (0)

// GLSL 450: layout(local_size_x = 64) in; layout(binding = 0) buffer B { uint d[]; };
//           void main() { uint x = gl_GlobalInvocationID.x; d[x] = x * 3u + 7u; }
static const uint32_t spirv[] = {
	0x07230203, 0x00010000, 0, 23, 0,
	(2 << 16) | 17, 1,                                    // OpCapability Shader
	(3 << 16) | 14, 0, 1,                                 // OpMemoryModel Logical GLSL450
	(6 << 16) | 15, 5, 1, 0x6E69616D, 0, 2,               // OpEntryPoint GLCompute %1 "main" %2
	(6 << 16) | 16, 1, 17, 64, 1, 1,                      // OpExecutionMode %1 LocalSize 64 1 1
	(4 << 16) | 71, 2, 11, 28,                            // OpDecorate %2 BuiltIn GlobalInvocationId
	(4 << 16) | 71, 8, 6, 4,                              // OpDecorate %8 ArrayStride 4
	(5 << 16) | 72, 9, 0, 35, 0,                          // OpMemberDecorate %9 0 Offset 0
	(3 << 16) | 71, 9, 3,                                 // OpDecorate %9 BufferBlock
	(4 << 16) | 71, 11, 34, 0,                            // OpDecorate %11 DescriptorSet 0
	(4 << 16) | 71, 11, 33, 0,                            // OpDecorate %11 Binding 0
	(2 << 16) | 19, 3,                                    // %3 = OpTypeVoid
	(3 << 16) | 33, 4, 3,                                 // %4 = OpTypeFunction %3
	(4 << 16) | 21, 5, 32, 0,                             // %5 = OpTypeInt 32 0
	(4 << 16) | 23, 6, 5, 3,                              // %6 = OpTypeVector %5 3
	(4 << 16) | 32, 7, 1, 6,                              // %7 = OpTypePointer Input %6
	(4 << 16) | 59, 7, 2, 1,                              // %2 = OpVariable %7 Input
	(3 << 16) | 29, 8, 5,                                 // %8 = OpTypeRuntimeArray %5
	(3 << 16) | 30, 9, 8,                                 // %9 = OpTypeStruct %8
	(4 << 16) | 32, 10, 2, 9,                             // %10 = OpTypePointer Uniform %9
	(4 << 16) | 59, 10, 11, 2,                            // %11 = OpVariable %10 Uniform
	(4 << 16) | 32, 12, 2, 5,                             // %12 = OpTypePointer Uniform %5
	(4 << 16) | 32, 13, 1, 5,                             // %13 = OpTypePointer Input %5
	(4 << 16) | 43, 5, 14, 0,                             // %14 = OpConstant %5 0
	(4 << 16) | 43, 5, 15, 3,                             // %15 = OpConstant %5 3
	(4 << 16) | 43, 5, 16, 7,                             // %16 = OpConstant %5 7
	(5 << 16) | 54, 3, 1, 0, 4,                           // %1 = OpFunction %3 None %4
	(2 << 16) | 248, 17,                                  // %17 = OpLabel
	(5 << 16) | 65, 13, 18, 2, 14,                        // %18 = OpAccessChain %13 %2 %14
	(4 << 16) | 61, 5, 19, 18,                            // %19 = OpLoad %5 %18
	(5 << 16) | 132, 5, 20, 19, 15,                       // %20 = OpIMul %5 %19 %15
	(5 << 16) | 128, 5, 21, 20, 16,                       // %21 = OpIAdd %5 %20 %16
	(6 << 16) | 65, 12, 22, 11, 14, 19,                   // %22 = OpAccessChain %12 %11 %14 %19
	(3 << 16) | 62, 22, 21,                               // OpStore %22 %21
	(1 << 16) | 253,                                      // OpReturn
	(1 << 16) | 56,                                       // OpFunctionEnd
};

static const char *type_name(VkPhysicalDeviceType t)
{
	switch (t) {
	case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated";
	case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: return "discrete";
	case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: return "virtual";
	case VK_PHYSICAL_DEVICE_TYPE_CPU: return "cpu";
	default: return "other";
	}
}

int main(int argc, char **argv)
{
	const uint32_t N = 1u << 20; // 1M uints, 16384 workgroups of 64
	uint32_t loader_ver = 0;
	CHECK(vkEnumerateInstanceVersion(&loader_ver));
	printf("loader instance version %u.%u.%u\n", VK_API_VERSION_MAJOR(loader_ver), VK_API_VERSION_MINOR(loader_ver),
	       VK_API_VERSION_PATCH(loader_ver));

	VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vk_compute",
				 .apiVersion = VK_API_VERSION_1_3};
	VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
	VkInstance instance;
	CHECK(vkCreateInstance(&ici, NULL, &instance));

	uint32_t n = 0;
	CHECK(vkEnumeratePhysicalDevices(instance, &n, NULL));
	VkPhysicalDevice pds[8];
	if (n > 8) n = 8;
	CHECK(vkEnumeratePhysicalDevices(instance, &n, pds));
	printf("%u physical device(s)\n", n);
	int pick = argc > 1 ? atoi(argv[1]) : -1;
	for (uint32_t i = 0; i < n; i++) {
		VkPhysicalDeviceDriverProperties drv = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
		VkPhysicalDeviceProperties2 p2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &drv};
		vkGetPhysicalDeviceProperties2(pds[i], &p2);
		VkPhysicalDeviceProperties *p = &p2.properties;
		printf("  [%u] %s  %04x:%04x %s  api %u.%u.%u  driver %s (%s)\n", i, p->deviceName, p->vendorID, p->deviceID,
		       type_name(p->deviceType), VK_API_VERSION_MAJOR(p->apiVersion), VK_API_VERSION_MINOR(p->apiVersion),
		       VK_API_VERSION_PATCH(p->apiVersion), drv.driverName, drv.driverInfo);
		if (pick < 0 && p->deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) pick = (int)i;
	}
	if (pick < 0 || (uint32_t)pick >= n) { printf("no discrete GPU\nFAIL\n"); return 1; }
	VkPhysicalDevice pd = pds[pick];

	uint32_t nq = 0;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, NULL);
	VkQueueFamilyProperties qf[16];
	if (nq > 16) nq = 16;
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qf);
	uint32_t qfi = UINT32_MAX;
	for (uint32_t i = 0; i < nq; i++)
		if (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { qfi = i; break; }
	if (qfi == UINT32_MAX) { printf("no compute queue\nFAIL\n"); return 1; }

	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = qfi,
				       .queueCount = 1, .pQueuePriorities = &prio};
	VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
				  .pQueueCreateInfos = &qci};
	VkDevice dev;
	CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
	printf("vkCreateDevice ok on [%d], queue family %u\n", pick, qfi);
	VkQueue q;
	vkGetDeviceQueue(dev, qfi, 0, &q);

	VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = (VkDeviceSize)N * 4,
				  .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT};
	VkBuffer buf;
	CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
	VkMemoryRequirements mr;
	vkGetBufferMemoryRequirements(dev, buf, &mr);
	VkPhysicalDeviceMemoryProperties mp;
	vkGetPhysicalDeviceMemoryProperties(pd, &mp);
	uint32_t mt = UINT32_MAX;
	const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
		if ((mr.memoryTypeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) { mt = i; break; }
	if (mt == UINT32_MAX) { printf("no host-visible coherent memory type\nFAIL\n"); return 1; }
	VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size,
				    .memoryTypeIndex = mt};
	VkDeviceMemory mem;
	CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
	CHECK(vkBindBufferMemory(dev, buf, mem, 0));
	uint32_t *map;
	CHECK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&map));
	memset(map, 0xcd, (size_t)N * 4);

	VkShaderModuleCreateInfo smci = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof spirv,
					 .pCode = spirv};
	VkShaderModule sm;
	CHECK(vkCreateShaderModule(dev, &smci, NULL, &sm));
	VkDescriptorSetLayoutBinding b = {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
					  .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT};
	VkDescriptorSetLayoutCreateInfo dslci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
						 .bindingCount = 1, .pBindings = &b};
	VkDescriptorSetLayout dsl;
	CHECK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
	VkPipelineLayoutCreateInfo plci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1,
					   .pSetLayouts = &dsl};
	VkPipelineLayout pl;
	CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &pl));
	VkComputePipelineCreateInfo cpci = {
		.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
		.stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
			  .module = sm, .pName = "main"},
		.layout = pl};
	VkPipeline pipe;
	CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));

	VkDescriptorPoolSize ps = {.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1};
	VkDescriptorPoolCreateInfo dpci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
					   .poolSizeCount = 1, .pPoolSizes = &ps};
	VkDescriptorPool dp;
	CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &dp));
	VkDescriptorSetAllocateInfo dsai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp,
					    .descriptorSetCount = 1, .pSetLayouts = &dsl};
	VkDescriptorSet ds;
	CHECK(vkAllocateDescriptorSets(dev, &dsai, &ds));
	VkDescriptorBufferInfo dbi = {.buffer = buf, .offset = 0, .range = VK_WHOLE_SIZE};
	VkWriteDescriptorSet w = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 0,
				  .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi};
	vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);

	VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = qfi};
	VkCommandPool cp;
	CHECK(vkCreateCommandPool(dev, &cpi, NULL, &cp));
	VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp,
					    .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
	VkCommandBuffer cb;
	CHECK(vkAllocateCommandBuffers(dev, &cbai, &cb));
	VkCommandBufferBeginInfo cbbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
					 .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
	CHECK(vkBeginCommandBuffer(cb, &cbbi));
	vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
	vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, NULL);
	vkCmdDispatch(cb, N / 64, 1, 1);
	VkMemoryBarrier mb = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
			      .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
	vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0,
			     NULL);
	CHECK(vkEndCommandBuffer(cb));

	VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	VkFence f;
	CHECK(vkCreateFence(dev, &fci, NULL, &f));
	VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
	struct timespec t0, t1;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	CHECK(vkQueueSubmit(q, 1, &si, f));
	CHECK(vkWaitForFences(dev, 1, &f, VK_TRUE, 5ull * 1000 * 1000 * 1000));
	clock_gettime(CLOCK_MONOTONIC, &t1);

	uint32_t bad = 0, first_bad = UINT32_MAX;
	for (uint32_t i = 0; i < N; i++)
		if (map[i] != i * 3u + 7u) { if (first_bad == UINT32_MAX) first_bad = i; bad++; }
	printf("dispatch %u x 64 invocations: %.3f ms submit->fence, %u/%u values wrong", N / 64,
	       (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6, bad, N);
	if (bad) printf(" (first at %u: 0x%08x)", first_bad, map[first_bad]);
	printf("\n%s\n", bad ? "FAIL" : "PASS");

	vkDestroyFence(dev, f, NULL);
	vkDestroyCommandPool(dev, cp, NULL);
	vkDestroyDescriptorPool(dev, dp, NULL);
	vkDestroyPipeline(dev, pipe, NULL);
	vkDestroyPipelineLayout(dev, pl, NULL);
	vkDestroyDescriptorSetLayout(dev, dsl, NULL);
	vkDestroyShaderModule(dev, sm, NULL);
	vkUnmapMemory(dev, mem);
	vkFreeMemory(dev, mem, NULL);
	vkDestroyBuffer(dev, buf, NULL);
	vkDestroyDevice(dev, NULL);
	vkDestroyInstance(instance, NULL);
	return bad ? 1 : 0;
}
