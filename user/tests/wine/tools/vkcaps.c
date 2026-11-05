// SPDX-License-Identifier: MIT
/* vkcaps: dumps what DXVK / vkd3d-proton / winevulkan care about, through the Khronos loader.
 * Build: clang -arch x86_64 -I<mesa>/include vkcaps.c -o vkcaps ; run: ./vkcaps [libvulkan path] */
#include <dlfcn.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static PFN_vkGetInstanceProcAddr gipa;
#define IPROC(n) PFN_##n n = (PFN_##n)gipa(inst, #n)

int main(int argc, char **argv)
{
	const char *lib = argc > 1 ? argv[1] : "/usr/local/lib/libvulkan.1.dylib";
	void *h = dlopen(lib, RTLD_NOW);
	if (!h) { printf("dlopen %s: %s\n", lib, dlerror()); return 1; }
	gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr");
	VkInstance inst = NULL;
	PFN_vkEnumerateInstanceExtensionProperties eie = (void *)gipa(NULL, "vkEnumerateInstanceExtensionProperties");
	uint32_t n = 0; eie(NULL, &n, NULL);
	VkExtensionProperties *ie = calloc(n, sizeof(*ie)); eie(NULL, &n, ie);
	printf("== instance extensions (%u)\n", n);
	for (uint32_t i = 0; i < n; i++) printf("I %s %u\n", ie[i].extensionName, ie[i].specVersion);
	const char *want[] = {"VK_KHR_surface", "VK_EXT_metal_surface", "VK_KHR_portability_enumeration", "VK_KHR_get_surface_capabilities2", "VK_EXT_surface_maintenance1", "VK_KHR_surface_maintenance1"};
	const char *en[8]; uint32_t ne = 0;
	for (unsigned w = 0; w < sizeof(want)/sizeof(want[0]); w++)
		for (uint32_t i = 0; i < n; i++) if (!strcmp(ie[i].extensionName, want[w])) en[ne++] = want[w];
	VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_4};
	VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai, .enabledExtensionCount = ne, .ppEnabledExtensionNames = en};
	for (uint32_t i = 0; i < ne; i++) if (!strcmp(en[i], "VK_KHR_portability_enumeration")) ici.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
	PFN_vkCreateInstance ci = (void *)gipa(NULL, "vkCreateInstance");
	VkResult r = ci(&ici, NULL, &inst);
	if (r) { printf("vkCreateInstance %d\n", r); return 1; }
	IPROC(vkEnumeratePhysicalDevices); IPROC(vkGetPhysicalDeviceProperties2); IPROC(vkGetPhysicalDeviceFeatures2);
	IPROC(vkEnumerateDeviceExtensionProperties); IPROC(vkGetPhysicalDeviceMemoryProperties2);
	uint32_t np = 0; vkEnumeratePhysicalDevices(inst, &np, NULL);
	VkPhysicalDevice pd[8]; if (np > 8) np = 8; vkEnumeratePhysicalDevices(inst, &np, pd);
	printf("== physical devices %u\n", np);
	for (uint32_t d = 0; d < np; d++) {
		VkPhysicalDeviceDriverProperties drv = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
		VkPhysicalDeviceVulkan11Properties p11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES, &drv};
		VkPhysicalDeviceVulkan12Properties p12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES, &p11};
		VkPhysicalDeviceVulkan13Properties p13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_PROPERTIES, &p12};
		VkPhysicalDeviceIDProperties idp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES, &p13};
		VkPhysicalDeviceProperties2 p = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &p13};
		(void)idp;
		vkGetPhysicalDeviceProperties2(pd[d], &p);
		VkPhysicalDeviceLimits *l = &p.properties.limits;
		printf("D name %s\nD api %u.%u.%u driverVersion 0x%x vendor %04x device %04x\nD driver %s / %s (id %d) conformance %u.%u.%u.%u\n",
		       p.properties.deviceName, VK_API_VERSION_MAJOR(p.properties.apiVersion), VK_API_VERSION_MINOR(p.properties.apiVersion),
		       VK_API_VERSION_PATCH(p.properties.apiVersion), p.properties.driverVersion, p.properties.vendorID, p.properties.deviceID,
		       drv.driverName, drv.driverInfo, drv.driverID, drv.conformanceVersion.major, drv.conformanceVersion.minor,
		       drv.conformanceVersion.subminor, drv.conformanceVersion.patch);
		printf("D deviceLUIDValid %u\n", p11.deviceLUIDValid);
		printf("L maxPushConstantsSize %u maxBoundDescriptorSets %u maxMemoryAllocationCount %u maxSamplerAllocationCount %u\n",
		       l->maxPushConstantsSize, l->maxBoundDescriptorSets, l->maxMemoryAllocationCount, l->maxSamplerAllocationCount);
		printf("L maxImageDimension2D %u 3D %u arrayLayers %u maxViewports %u maxColorAttachments %u maxSamplerAnisotropy %.0f\n",
		       l->maxImageDimension2D, l->maxImageDimension3D, l->maxImageArrayLayers, l->maxViewports, l->maxColorAttachments, l->maxSamplerAnisotropy);
		printf("L minUniformBufferOffsetAlignment %" PRIu64 " minStorageBufferOffsetAlignment %" PRIu64 " minTexelBufferOffsetAlignment %" PRIu64 " nonCoherentAtomSize %" PRIu64 " bufferImageGranularity %" PRIu64 "\n",
		       l->minUniformBufferOffsetAlignment, l->minStorageBufferOffsetAlignment, l->minTexelBufferOffsetAlignment, l->nonCoherentAtomSize, l->bufferImageGranularity);
		printf("L subgroupSize %u min %u max %u requiredSubgroupSizeStages 0x%x subgroupOps 0x%x stages 0x%x\n",
		       p11.subgroupSize, p13.minSubgroupSize, p13.maxSubgroupSize, p13.requiredSubgroupSizeStages, p11.subgroupSupportedOperations, p11.subgroupSupportedStages);
		printf("L maxUpdateAfterBindDescriptorsInAllPools %u maxPerStageUAB samplers %u sampled %u storageImg %u storageBuf %u ubo %u resources %u\n",
		       p12.maxUpdateAfterBindDescriptorsInAllPools, p12.maxPerStageDescriptorUpdateAfterBindSamplers,
		       p12.maxPerStageDescriptorUpdateAfterBindSampledImages, p12.maxPerStageDescriptorUpdateAfterBindStorageImages,
		       p12.maxPerStageDescriptorUpdateAfterBindStorageBuffers, p12.maxPerStageDescriptorUpdateAfterBindUniformBuffers,
		       p12.maxPerStageUpdateAfterBindResources);
		printf("L maxTimelineSemaphoreValueDifference %" PRIu64 " maxBufferSize %" PRIu64 " maxMemoryAllocationSize %" PRIu64 " maxInlineUniformBlockSize %u\n",
		       p12.maxTimelineSemaphoreValueDifference, p13.maxBufferSize, p11.maxMemoryAllocationSize, p13.maxInlineUniformBlockSize);
		VkPhysicalDeviceMemoryProperties2 mp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2};
		vkGetPhysicalDeviceMemoryProperties2(pd[d], &mp);
		for (uint32_t i = 0; i < mp.memoryProperties.memoryHeapCount; i++)
			printf("M heap %u %" PRIu64 " MB flags 0x%x\n", i, mp.memoryProperties.memoryHeaps[i].size >> 20, mp.memoryProperties.memoryHeaps[i].flags);
		for (uint32_t i = 0; i < mp.memoryProperties.memoryTypeCount; i++)
			printf("M type %u heap %u flags 0x%x\n", i, mp.memoryProperties.memoryTypes[i].heapIndex, mp.memoryProperties.memoryTypes[i].propertyFlags);

		uint32_t nd = 0; vkEnumerateDeviceExtensionProperties(pd[d], NULL, &nd, NULL);
		VkExtensionProperties *de = calloc(nd, sizeof(*de)); vkEnumerateDeviceExtensionProperties(pd[d], NULL, &nd, de);
		printf("== device extensions (%u)\n", nd);
		for (uint32_t i = 0; i < nd; i++) printf("E %s %u\n", de[i].extensionName, de[i].specVersion);

		VkPhysicalDeviceRobustness2FeaturesKHR rb2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_KHR};
		VkPhysicalDeviceDepthClipEnableFeaturesEXT dce = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT, &rb2};
		VkPhysicalDeviceCustomBorderColorFeaturesEXT cbc = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CUSTOM_BORDER_COLOR_FEATURES_EXT, &dce};
		VkPhysicalDeviceExtendedDynamicState3FeaturesEXT eds3 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT, &cbc};
		VkPhysicalDeviceGraphicsPipelineLibraryFeaturesEXT gpl = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_GRAPHICS_PIPELINE_LIBRARY_FEATURES_EXT, &eds3};
		VkPhysicalDeviceDescriptorBufferFeaturesEXT db = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT, &gpl};
		VkPhysicalDeviceMutableDescriptorTypeFeaturesEXT mdt = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MUTABLE_DESCRIPTOR_TYPE_FEATURES_EXT, &db};
		VkPhysicalDeviceTransformFeedbackFeaturesEXT xfb = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT, &mdt};
		VkPhysicalDevicePresentIdFeaturesKHR pid = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR, &xfb};
		VkPhysicalDevicePresentWaitFeaturesKHR pw = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR, &pid};
		VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR sm1 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR, &pw};
		VkPhysicalDeviceMemoryPriorityFeaturesEXT mpr = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PRIORITY_FEATURES_EXT, &sm1};
		VkPhysicalDeviceAttachmentFeedbackLoopLayoutFeaturesEXT afl = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ATTACHMENT_FEEDBACK_LOOP_LAYOUT_FEATURES_EXT, &mpr};
		VkPhysicalDeviceNonSeamlessCubeMapFeaturesEXT nsc = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_NON_SEAMLESS_CUBE_MAP_FEATURES_EXT, &afl};
		VkPhysicalDeviceShaderModuleIdentifierFeaturesEXT smi = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_MODULE_IDENTIFIER_FEATURES_EXT, &nsc};
		VkPhysicalDeviceFragmentShaderInterlockFeaturesEXT fsi = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT, &smi};
		VkPhysicalDeviceMultiDrawFeaturesEXT mdr = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTI_DRAW_FEATURES_EXT, &fsi};
		VkPhysicalDeviceDynamicRenderingUnusedAttachmentsFeaturesEXT drua = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_UNUSED_ATTACHMENTS_FEATURES_EXT, &mdr};
		VkPhysicalDeviceDepthBiasControlFeaturesEXT dbc = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_BIAS_CONTROL_FEATURES_EXT, &drua};
		VkPhysicalDeviceBorderColorSwizzleFeaturesEXT bcs = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BORDER_COLOR_SWIZZLE_FEATURES_EXT, &dbc};
		VkPhysicalDeviceMaintenance7FeaturesKHR m7 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_7_FEATURES_KHR, &bcs};
		VkPhysicalDeviceMaintenance8FeaturesKHR m8 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_8_FEATURES_KHR, &m7};
		VkPhysicalDeviceMaintenance9FeaturesKHR m9 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_9_FEATURES_KHR, &m8};
		VkPhysicalDeviceImage2DViewOf3DFeaturesEXT i2d = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_2D_VIEW_OF_3D_FEATURES_EXT, &m9};
		VkPhysicalDeviceLineRasterizationFeaturesKHR lr = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_LINE_RASTERIZATION_FEATURES_KHR, &i2d};
		VkPhysicalDeviceFragmentShadingRateFeaturesKHR fsr = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADING_RATE_FEATURES_KHR, &lr};
		VkPhysicalDeviceMeshShaderFeaturesEXT msh = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT, &fsr};
		VkPhysicalDeviceRayTracingPipelineFeaturesKHR rtp = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_TRACING_PIPELINE_FEATURES_KHR, &msh};
		VkPhysicalDeviceAccelerationStructureFeaturesKHR acs = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR, &rtp};
		VkPhysicalDeviceShaderFloatControls2FeaturesKHR fc2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_FLOAT_CONTROLS_2_FEATURES_KHR, &acs};
		VkPhysicalDeviceVulkan14Features v14 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES, &fc2};
		VkPhysicalDeviceVulkan13Features v13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &v14};
		VkPhysicalDeviceVulkan12Features v12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, &v13};
		VkPhysicalDeviceVulkan11Features v11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, &v12};
		VkPhysicalDeviceFeatures2 f = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &v11};
		vkGetPhysicalDeviceFeatures2(pd[d], &f);
		VkPhysicalDeviceFeatures *c = &f.features;
#define F(s, x) printf("F %-14s %-48s %u\n", #s, #x, (s)->x)
		F(c, depthBiasClamp); F(c, depthBounds); F(c, depthClamp); F(c, dualSrcBlend); F(c, fillModeNonSolid);
		F(c, fragmentStoresAndAtomics); F(c, fullDrawIndexUint32); F(c, geometryShader); F(c, imageCubeArray); F(c, independentBlend);
		F(c, multiDrawIndirect); F(c, multiViewport); F(c, occlusionQueryPrecise); F(c, pipelineStatisticsQuery); F(c, robustBufferAccess);
		F(c, sampleRateShading); F(c, samplerAnisotropy); F(c, shaderClipDistance); F(c, shaderCullDistance); F(c, shaderFloat64);
		F(c, shaderImageGatherExtended); F(c, shaderInt16); F(c, shaderInt64); F(c, shaderSampledImageArrayDynamicIndexing);
		F(c, sparseBinding); F(c, sparseResidencyBuffer); F(c, sparseResidencyImage2D); F(c, sparseResidencyImage3D);
		F(c, shaderResourceResidency); F(c, shaderResourceMinLod); F(c, tessellationShader); F(c, textureCompressionBC);
		F(c, vertexPipelineStoresAndAtomics); F(c, wideLines); F(c, logicOp); F(c, largePoints); F(c, variableMultisampleRate);
		F(c, shaderStorageImageReadWithoutFormat); F(c, shaderStorageImageWriteWithoutFormat); F(c, shaderStorageImageExtendedFormats);
		F(c, drawIndirectFirstInstance); F(c, depthBounds); F(c, alphaToOne);
		F(&v11, shaderDrawParameters); F(&v11, storageBuffer16BitAccess); F(&v11, storagePushConstant16); F(&v11, multiview);
		F(&v12, bufferDeviceAddress); F(&v12, descriptorIndexing); F(&v12, storageBuffer8BitAccess); F(&v12, drawIndirectCount);
		F(&v12, descriptorBindingSampledImageUpdateAfterBind); F(&v12, descriptorBindingStorageImageUpdateAfterBind);
		F(&v12, descriptorBindingStorageBufferUpdateAfterBind); F(&v12, descriptorBindingUniformBufferUpdateAfterBind);
		F(&v12, descriptorBindingUniformTexelBufferUpdateAfterBind); F(&v12, descriptorBindingStorageTexelBufferUpdateAfterBind);
		F(&v12, descriptorBindingUpdateUnusedWhilePending); F(&v12, descriptorBindingPartiallyBound); F(&v12, descriptorBindingVariableDescriptorCount);
		F(&v12, hostQueryReset); F(&v12, runtimeDescriptorArray); F(&v12, samplerFilterMinmax); F(&v12, samplerMirrorClampToEdge);
		F(&v12, scalarBlockLayout); F(&v12, shaderFloat16); F(&v12, shaderInt8); F(&v12, shaderOutputViewportIndex); F(&v12, shaderOutputLayer);
		F(&v12, timelineSemaphore); F(&v12, uniformBufferStandardLayout); F(&v12, vulkanMemoryModel); F(&v12, vulkanMemoryModelDeviceScope);
		F(&v12, shaderBufferInt64Atomics); F(&v12, shaderSharedInt64Atomics); F(&v12, imagelessFramebuffer); F(&v12, separateDepthStencilLayouts);
		F(&v12, shaderSubgroupExtendedTypes); F(&v12, bufferDeviceAddressCaptureReplay);
		F(&v13, inlineUniformBlock); F(&v13, computeFullSubgroups); F(&v13, dynamicRendering); F(&v13, maintenance4); F(&v13, robustImageAccess);
		F(&v13, pipelineCreationCacheControl); F(&v13, shaderDemoteToHelperInvocation); F(&v13, shaderZeroInitializeWorkgroupMemory);
		F(&v13, subgroupSizeControl); F(&v13, synchronization2); F(&v13, shaderIntegerDotProduct); F(&v13, textureCompressionASTC_HDR);
		F(&v14, maintenance5); F(&v14, maintenance6); F(&v14, pushDescriptor); F(&v14, dynamicRenderingLocalRead);
		F(&v14, vertexAttributeInstanceRateDivisor); F(&v14, vertexAttributeInstanceRateZeroDivisor); F(&v14, indexTypeUint8);
		F(&v14, globalPriorityQuery); F(&v14, shaderSubgroupRotate); F(&v14, shaderFloatControls2); F(&v14, shaderExpectAssume);
		F(&v14, rectangularLines); F(&v14, smoothLines); F(&v14, pipelineRobustness); F(&v14, hostImageCopy);
		F(&rb2, robustBufferAccess2); F(&rb2, robustImageAccess2); F(&rb2, nullDescriptor);
		F(&dce, depthClipEnable); F(&cbc, customBorderColors); F(&cbc, customBorderColorWithoutFormat);
		F(&eds3, extendedDynamicState3AlphaToCoverageEnable); F(&eds3, extendedDynamicState3DepthClipEnable);
		F(&eds3, extendedDynamicState3RasterizationSamples); F(&eds3, extendedDynamicState3SampleMask);
		F(&eds3, extendedDynamicState3LineRasterizationMode); F(&eds3, extendedDynamicState3SampleLocationsEnable);
		F(&gpl, graphicsPipelineLibrary); F(&db, descriptorBuffer); F(&db, descriptorBufferPushDescriptors); F(&mdt, mutableDescriptorType);
		F(&xfb, transformFeedback); F(&xfb, geometryStreams); F(&pid, presentId); F(&pw, presentWait); F(&sm1, swapchainMaintenance1);
		F(&mpr, memoryPriority); F(&afl, attachmentFeedbackLoopLayout); F(&nsc, nonSeamlessCubeMap); F(&smi, shaderModuleIdentifier);
		F(&fsi, fragmentShaderSampleInterlock); F(&fsi, fragmentShaderPixelInterlock); F(&mdr, multiDraw);
		F(&drua, dynamicRenderingUnusedAttachments); F(&dbc, depthBiasControl); F(&dbc, depthBiasExact);
		F(&bcs, borderColorSwizzle); F(&bcs, borderColorSwizzleFromImage); F(&m7, maintenance7); F(&m8, maintenance8); F(&m9, maintenance9);
		F(&i2d, image2DViewOf3D); F(&lr, rectangularLines); F(&fsr, pipelineFragmentShadingRate); F(&fsr, attachmentFragmentShadingRate);
		F(&msh, meshShader); F(&msh, taskShader); F(&rtp, rayTracingPipeline); F(&acs, accelerationStructure); F(&fc2, shaderFloatControls2);
	}
	PFN_vkDestroyInstance di = (void *)gipa(inst, "vkDestroyInstance");
	di(inst, NULL);
	return 0;
}
