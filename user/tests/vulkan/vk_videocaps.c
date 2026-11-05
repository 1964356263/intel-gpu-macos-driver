// vk_videocaps: loads Mesa's libvulkan_intel.dylib directly and prints the video decode capabilities it reports for
// H.264 High, H.265 Main, AV1 Main and VP9 profile 0 (8-bit 4:2:0), then the encode extensions and the encode
// capabilities for H.264 High, H.265 Main/Main10 and AV1 Main. Needs ANV_DEBUG=video-decode (add video-encode for the
// encode part) and, on the B580, sysctl debug.intelxe.video=1 before it starts.
// SPDX-License-Identifier: MIT
//
//   run: ANV_DEBUG=video-decode,video-encode tests/vk_videocaps [path/to/libvulkan_intel.dylib]

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#include <vulkan/vulkan.h>

static PFN_vkGetInstanceProcAddr gipa;
#define IFN(name) PFN_##name name = (PFN_##name)gipa(instance, #name)

int main(int argc, char **argv)
{
	void *lib = dlopen(argc > 1 ? argv[1] : "libvulkan_intel.dylib", RTLD_NOW | RTLD_LOCAL);
	if (!lib || !(gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr"))) {
		printf("cannot load the ICD: %s\n", dlerror());
		return 1;
	}
	VkInstance instance = VK_NULL_HANDLE;
	IFN(vkCreateInstance);
	VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vk_videocaps",
				 .apiVersion = VK_API_VERSION_1_3};
	VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
	if (vkCreateInstance(&ici, NULL, &instance)) return 1;
	IFN(vkEnumeratePhysicalDevices);
	IFN(vkGetPhysicalDeviceVideoCapabilitiesKHR);
	IFN(vkGetPhysicalDeviceVideoFormatPropertiesKHR);
	VkPhysicalDevice pd;
	uint32_t n = 1;
	if (vkEnumeratePhysicalDevices(instance, &n, &pd) || !n) return 1;
	if (!vkGetPhysicalDeviceVideoCapabilitiesKHR) { printf("no VK_KHR_video_queue\n"); return 1; }
	{	// the decode extensions the device exposes (H.265 only with has_huc), and the video queue family
		IFN(vkEnumerateDeviceExtensionProperties);
		IFN(vkGetPhysicalDeviceQueueFamilyProperties);
		VkExtensionProperties ext[400];
		uint32_t ne = 400;
		vkEnumerateDeviceExtensionProperties(pd, NULL, &ne, ext);
		printf("decode extensions:");
		for (uint32_t i = 0; i < ne; i++)
			if (strstr(ext[i].extensionName, "video_decode")) printf(" %s", ext[i].extensionName);
		VkQueueFamilyProperties qf[8];
		uint32_t nq = 8;
		vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qf);
		printf("\nencode extensions:");
		for (uint32_t i = 0; i < ne; i++)
			if (strstr(ext[i].extensionName, "video_encode")) printf(" %s", ext[i].extensionName);
		printf("\nqueue families:");
		VkQueueFamilyProperties2 qf2[8];
		VkQueueFamilyVideoPropertiesKHR qv[8];
		for (uint32_t i = 0; i < 8; i++) {
			qv[i] = (VkQueueFamilyVideoPropertiesKHR){.sType = VK_STRUCTURE_TYPE_QUEUE_FAMILY_VIDEO_PROPERTIES_KHR};
			qf2[i] = (VkQueueFamilyProperties2){.sType = VK_STRUCTURE_TYPE_QUEUE_FAMILY_PROPERTIES_2, .pNext = &qv[i]};
		}
		IFN(vkGetPhysicalDeviceQueueFamilyProperties2);
		uint32_t nq2 = 8;
		if (vkGetPhysicalDeviceQueueFamilyProperties2) vkGetPhysicalDeviceQueueFamilyProperties2(pd, &nq2, qf2);
		for (uint32_t i = 0; i < nq; i++)
			printf(" [%u] flags 0x%x x%u codecs 0x%x", i, qf[i].queueFlags, qf[i].queueCount,
			       i < nq2 ? qv[i].videoCodecOperations : 0);
		printf("\n");
	}

	VkVideoDecodeH264ProfileInfoKHR h264 = {.sType = VK_STRUCTURE_TYPE_VIDEO_DECODE_H264_PROFILE_INFO_KHR,
		.stdProfileIdc = STD_VIDEO_H264_PROFILE_IDC_HIGH, .pictureLayout = VK_VIDEO_DECODE_H264_PICTURE_LAYOUT_PROGRESSIVE_KHR};
	VkVideoDecodeH265ProfileInfoKHR h265 = {.sType = VK_STRUCTURE_TYPE_VIDEO_DECODE_H265_PROFILE_INFO_KHR,
		.stdProfileIdc = STD_VIDEO_H265_PROFILE_IDC_MAIN};
	VkVideoDecodeAV1ProfileInfoKHR av1 = {.sType = VK_STRUCTURE_TYPE_VIDEO_DECODE_AV1_PROFILE_INFO_KHR,
		.stdProfile = STD_VIDEO_AV1_PROFILE_MAIN};
	VkVideoDecodeVP9ProfileInfoKHR vp9 = {.sType = VK_STRUCTURE_TYPE_VIDEO_DECODE_VP9_PROFILE_INFO_KHR,
		.stdProfile = STD_VIDEO_VP9_PROFILE_0};
	struct { const char *name; VkVideoCodecOperationFlagBitsKHR op; const void *ext; } codecs[] = {
		{"H.264 High", VK_VIDEO_CODEC_OPERATION_DECODE_H264_BIT_KHR, &h264},
		{"H.265 Main", VK_VIDEO_CODEC_OPERATION_DECODE_H265_BIT_KHR, &h265},
		{"AV1 Main", VK_VIDEO_CODEC_OPERATION_DECODE_AV1_BIT_KHR, &av1},
		{"VP9 Profile 0", VK_VIDEO_CODEC_OPERATION_DECODE_VP9_BIT_KHR, &vp9},
	};
	for (unsigned i = 0; i < sizeof(codecs) / sizeof(codecs[0]); i++) {
		VkVideoProfileInfoKHR prof = {.sType = VK_STRUCTURE_TYPE_VIDEO_PROFILE_INFO_KHR, .pNext = codecs[i].ext,
			.videoCodecOperation = codecs[i].op, .chromaSubsampling = VK_VIDEO_CHROMA_SUBSAMPLING_420_BIT_KHR,
			.lumaBitDepth = VK_VIDEO_COMPONENT_BIT_DEPTH_8_BIT_KHR, .chromaBitDepth = VK_VIDEO_COMPONENT_BIT_DEPTH_8_BIT_KHR};
		VkVideoDecodeCapabilitiesKHR dec = {.sType = VK_STRUCTURE_TYPE_VIDEO_DECODE_CAPABILITIES_KHR};
		VkVideoCapabilitiesKHR caps = {.sType = VK_STRUCTURE_TYPE_VIDEO_CAPABILITIES_KHR, .pNext = &dec};
		// codec-specific capability structs (required by the spec in the chain)
		VkVideoDecodeH264CapabilitiesKHR c264 = {.sType = VK_STRUCTURE_TYPE_VIDEO_DECODE_H264_CAPABILITIES_KHR};
		VkVideoDecodeH265CapabilitiesKHR c265 = {.sType = VK_STRUCTURE_TYPE_VIDEO_DECODE_H265_CAPABILITIES_KHR};
		VkVideoDecodeAV1CapabilitiesKHR cav1 = {.sType = VK_STRUCTURE_TYPE_VIDEO_DECODE_AV1_CAPABILITIES_KHR};
		VkVideoDecodeVP9CapabilitiesKHR cvp9 = {.sType = VK_STRUCTURE_TYPE_VIDEO_DECODE_VP9_CAPABILITIES_KHR};
		dec.pNext = i == 0 ? (void *)&c264 : i == 1 ? (void *)&c265 : i == 2 ? (void *)&cav1 : (void *)&cvp9;
		VkResult r = vkGetPhysicalDeviceVideoCapabilitiesKHR(pd, &prof, &caps);
		if (r) { printf("%-14s not supported (VkResult %d)\n", codecs[i].name, r); continue; }
		printf("%-14s max %ux%u, min %ux%u, DPB slots %u, active refs %u, decode flags 0x%x\n", codecs[i].name,
		       caps.maxCodedExtent.width, caps.maxCodedExtent.height, caps.minCodedExtent.width, caps.minCodedExtent.height,
		       caps.maxDpbSlots, caps.maxActiveReferencePictures, dec.flags);
		VkVideoProfileListInfoKHR list = {.sType = VK_STRUCTURE_TYPE_VIDEO_PROFILE_LIST_INFO_KHR, .profileCount = 1, .pProfiles = &prof};
		VkPhysicalDeviceVideoFormatInfoKHR fi = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VIDEO_FORMAT_INFO_KHR, .pNext = &list,
			.imageUsage = VK_IMAGE_USAGE_VIDEO_DECODE_DST_BIT_KHR};
		uint32_t nf = 0;
		if (!vkGetPhysicalDeviceVideoFormatPropertiesKHR(pd, &fi, &nf, NULL) && nf) {
			VkVideoFormatPropertiesKHR fp[8];
			for (uint32_t k = 0; k < 8; k++) fp[k] = (VkVideoFormatPropertiesKHR){.sType = VK_STRUCTURE_TYPE_VIDEO_FORMAT_PROPERTIES_KHR};
			if (nf > 8) nf = 8;
			vkGetPhysicalDeviceVideoFormatPropertiesKHR(pd, &fi, &nf, fp);
			printf("               output formats:");
			for (uint32_t k = 0; k < nf; k++) printf(" %d", fp[k].format);
			printf("\n");
		}
	}
	// encode: H.264 High, H.265 Main, H.265 Main10 (P010), AV1 Main
	VkVideoEncodeH264ProfileInfoKHR e264 = {.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_PROFILE_INFO_KHR,
		.stdProfileIdc = STD_VIDEO_H264_PROFILE_IDC_HIGH};
	VkVideoEncodeH265ProfileInfoKHR e265 = {.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_H265_PROFILE_INFO_KHR,
		.stdProfileIdc = STD_VIDEO_H265_PROFILE_IDC_MAIN};
	VkVideoEncodeH265ProfileInfoKHR e265_10 = {.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_H265_PROFILE_INFO_KHR,
		.stdProfileIdc = STD_VIDEO_H265_PROFILE_IDC_MAIN_10};
	VkVideoEncodeAV1ProfileInfoKHR eav1 = {.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_AV1_PROFILE_INFO_KHR,
		.stdProfile = STD_VIDEO_AV1_PROFILE_MAIN};
	struct { const char *name; VkVideoCodecOperationFlagBitsKHR op; const void *ext; VkVideoComponentBitDepthFlagsKHR depth; } ecodecs[] = {
		{"enc H.264 High", VK_VIDEO_CODEC_OPERATION_ENCODE_H264_BIT_KHR, &e264, VK_VIDEO_COMPONENT_BIT_DEPTH_8_BIT_KHR},
		{"enc H.265 Main", VK_VIDEO_CODEC_OPERATION_ENCODE_H265_BIT_KHR, &e265, VK_VIDEO_COMPONENT_BIT_DEPTH_8_BIT_KHR},
		{"enc H.265 M10", VK_VIDEO_CODEC_OPERATION_ENCODE_H265_BIT_KHR, &e265_10, VK_VIDEO_COMPONENT_BIT_DEPTH_10_BIT_KHR},
		{"enc AV1 Main", VK_VIDEO_CODEC_OPERATION_ENCODE_AV1_BIT_KHR, &eav1, VK_VIDEO_COMPONENT_BIT_DEPTH_8_BIT_KHR},
	};
	for (unsigned i = 0; i < sizeof(ecodecs) / sizeof(ecodecs[0]); i++) {
		VkVideoProfileInfoKHR prof = {.sType = VK_STRUCTURE_TYPE_VIDEO_PROFILE_INFO_KHR, .pNext = ecodecs[i].ext,
			.videoCodecOperation = ecodecs[i].op, .chromaSubsampling = VK_VIDEO_CHROMA_SUBSAMPLING_420_BIT_KHR,
			.lumaBitDepth = ecodecs[i].depth, .chromaBitDepth = ecodecs[i].depth};
		VkVideoEncodeCapabilitiesKHR enc = {.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_CAPABILITIES_KHR};
		VkVideoCapabilitiesKHR caps = {.sType = VK_STRUCTURE_TYPE_VIDEO_CAPABILITIES_KHR, .pNext = &enc};
		VkVideoEncodeH264CapabilitiesKHR c264 = {.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_H264_CAPABILITIES_KHR};
		VkVideoEncodeH265CapabilitiesKHR c265 = {.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_H265_CAPABILITIES_KHR};
		VkVideoEncodeAV1CapabilitiesKHR cav1 = {.sType = VK_STRUCTURE_TYPE_VIDEO_ENCODE_AV1_CAPABILITIES_KHR};
		enc.pNext = ecodecs[i].op == VK_VIDEO_CODEC_OPERATION_ENCODE_H264_BIT_KHR ? (void *)&c264 :
			    ecodecs[i].op == VK_VIDEO_CODEC_OPERATION_ENCODE_H265_BIT_KHR ? (void *)&c265 : (void *)&cav1;
		VkResult r = vkGetPhysicalDeviceVideoCapabilitiesKHR(pd, &prof, &caps);
		if (r) { printf("%-14s not supported (VkResult %d)\n", ecodecs[i].name, r); continue; }
		printf("%-14s max %ux%u, min %ux%u, DPB slots %u, active refs %u\n", ecodecs[i].name,
		       caps.maxCodedExtent.width, caps.maxCodedExtent.height, caps.minCodedExtent.width, caps.minCodedExtent.height,
		       caps.maxDpbSlots, caps.maxActiveReferencePictures);
		printf("               rc modes 0x%x, max layers %u, max bitrate %llu, quality levels %u, feedback 0x%x, flags 0x%x\n",
		       enc.rateControlModes, enc.maxRateControlLayers, (unsigned long long)enc.maxBitrate, enc.maxQualityLevels,
		       enc.supportedEncodeFeedbackFlags, enc.flags);
		if (ecodecs[i].op == VK_VIDEO_CODEC_OPERATION_ENCODE_H264_BIT_KHR)
			printf("               h264 max level %d, slices %u, P refs %u, B refs %u/%u, QP %d..%d\n", c264.maxLevelIdc,
			       c264.maxSliceCount, c264.maxPPictureL0ReferenceCount, c264.maxBPictureL0ReferenceCount,
			       c264.maxL1ReferenceCount, c264.minQp, c264.maxQp);
		else if (ecodecs[i].op == VK_VIDEO_CODEC_OPERATION_ENCODE_H265_BIT_KHR)
			printf("               h265 max level %d, slice segs %u, P refs %u, B refs %u/%u, QP %d..%d, CTB 0x%x\n",
			       c265.maxLevelIdc, c265.maxSliceSegmentCount, c265.maxPPictureL0ReferenceCount,
			       c265.maxBPictureL0ReferenceCount, c265.maxL1ReferenceCount, c265.minQp, c265.maxQp, c265.ctbSizes);
		VkVideoProfileListInfoKHR list = {.sType = VK_STRUCTURE_TYPE_VIDEO_PROFILE_LIST_INFO_KHR, .profileCount = 1, .pProfiles = &prof};
		VkPhysicalDeviceVideoFormatInfoKHR fi = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VIDEO_FORMAT_INFO_KHR, .pNext = &list,
			.imageUsage = VK_IMAGE_USAGE_VIDEO_ENCODE_SRC_BIT_KHR};
		uint32_t nf = 0;
		if (!vkGetPhysicalDeviceVideoFormatPropertiesKHR(pd, &fi, &nf, NULL) && nf) {
			VkVideoFormatPropertiesKHR fp[8];
			for (uint32_t k = 0; k < 8; k++) fp[k] = (VkVideoFormatPropertiesKHR){.sType = VK_STRUCTURE_TYPE_VIDEO_FORMAT_PROPERTIES_KHR};
			if (nf > 8) nf = 8;
			vkGetPhysicalDeviceVideoFormatPropertiesKHR(pd, &fi, &nf, fp);
			printf("               input formats:");
			for (uint32_t k = 0; k < nf; k++) printf(" %d", fp[k].format);
			printf("\n");
		}
	}
	return 0;
}
