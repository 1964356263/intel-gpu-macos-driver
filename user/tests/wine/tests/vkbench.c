// SPDX-License-Identifier: MIT
/* vkbench.exe: Windows Vulkan swapchain benchmark (the vkcube role) for Wine.
 * Full-window fragment shader with a tunable loop, uncapped present mode, FPS per second on stdout.
 * Usage: vkbench.exe [seconds=10] [iters=16] [width=1280] [height=720] [mode=immediate|mailbox|fifo]
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define VK_USE_PLATFORM_WIN32_KHR
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include "bench_vert.h"
#include "bench_frag.h"

#define G(n) static PFN_##n n
G(vkGetInstanceProcAddr); G(vkCreateInstance); G(vkEnumerateInstanceExtensionProperties);
G(vkEnumeratePhysicalDevices); G(vkGetPhysicalDeviceProperties2); G(vkGetPhysicalDeviceQueueFamilyProperties);
G(vkCreateWin32SurfaceKHR); G(vkGetPhysicalDeviceSurfaceSupportKHR); G(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
G(vkGetPhysicalDeviceSurfaceFormatsKHR); G(vkGetPhysicalDeviceSurfacePresentModesKHR); G(vkCreateDevice);
G(vkGetDeviceProcAddr); G(vkGetDeviceQueue); G(vkCreateSwapchainKHR); G(vkGetSwapchainImagesKHR);
G(vkCreateImageView); G(vkCreateRenderPass); G(vkCreateFramebuffer); G(vkCreateShaderModule);
G(vkCreatePipelineLayout); G(vkCreateGraphicsPipelines); G(vkCreateCommandPool); G(vkAllocateCommandBuffers);
G(vkCreateSemaphore); G(vkCreateFence); G(vkWaitForFences); G(vkResetFences); G(vkAcquireNextImageKHR);
G(vkBeginCommandBuffer); G(vkCmdBeginRenderPass); G(vkCmdBindPipeline); G(vkCmdPushConstants); G(vkCmdDraw);
G(vkCmdEndRenderPass); G(vkEndCommandBuffer); G(vkQueueSubmit); G(vkQueuePresentKHR); G(vkDeviceWaitIdle);
G(vkResetCommandBuffer); G(vkCmdSetViewport); G(vkCmdSetScissor);

#define CK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { printf("FAIL %s -> %d (line %d)\n", #x, r_, __LINE__); fflush(stdout); ExitProcess(1); } } while (0)
#define IL(n) n = (PFN_##n)vkGetInstanceProcAddr(inst, #n)
#define DL(n) n = (PFN_##n)vkGetDeviceProcAddr(dev, #n)

static volatile int quit;
static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
	if (m == WM_CLOSE || m == WM_DESTROY) { quit = 1; return 0; }
	if (m == WM_KEYDOWN && w == VK_ESCAPE) { quit = 1; return 0; }
	return DefWindowProcA(h, m, w, l);
}

static double now(void)
{
	static LARGE_INTEGER f; LARGE_INTEGER c;
	if (!f.QuadPart) QueryPerformanceFrequency(&f);
	QueryPerformanceCounter(&c);
	return (double)c.QuadPart / (double)f.QuadPart;
}

int main(int argc, char **argv)
{
	int seconds = argc > 1 ? atoi(argv[1]) : 10, iters = argc > 2 ? atoi(argv[2]) : 16;
	int W = argc > 3 ? atoi(argv[3]) : 1280, H = argc > 4 ? atoi(argv[4]) : 720;
	const char *mode = argc > 5 ? argv[5] : "immediate";
	setvbuf(stdout, NULL, _IONBF, 0);

	HMODULE vk = LoadLibraryA("vulkan-1.dll");
	if (!vk) { printf("no vulkan-1.dll\n"); return 1; }
	vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)(void *)GetProcAddress(vk, "vkGetInstanceProcAddr");
	VkInstance inst = NULL;
	IL(vkCreateInstance); IL(vkEnumerateInstanceExtensionProperties);

	const char *iext[] = {"VK_KHR_surface", "VK_KHR_win32_surface"};
	VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "vkbench", .apiVersion = VK_API_VERSION_1_3};
	VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai, .enabledExtensionCount = 2, .ppEnabledExtensionNames = iext};
	CK(vkCreateInstance(&ici, NULL, &inst));
	IL(vkEnumeratePhysicalDevices); IL(vkGetPhysicalDeviceProperties2); IL(vkGetPhysicalDeviceQueueFamilyProperties);
	IL(vkCreateWin32SurfaceKHR); IL(vkGetPhysicalDeviceSurfaceSupportKHR); IL(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
	IL(vkGetPhysicalDeviceSurfaceFormatsKHR); IL(vkGetPhysicalDeviceSurfacePresentModesKHR); IL(vkCreateDevice); IL(vkGetDeviceProcAddr);

	uint32_t np = 0; CK(vkEnumeratePhysicalDevices(inst, &np, NULL));
	VkPhysicalDevice pds[8]; if (np > 8) np = 8; CK(vkEnumeratePhysicalDevices(inst, &np, pds));
	for (uint32_t i = 0; i < np; i++) {
		VkPhysicalDeviceDriverProperties drv = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
		VkPhysicalDeviceIDProperties id = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES, &drv};
		VkPhysicalDeviceProperties2 p = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &id};
		vkGetPhysicalDeviceProperties2(pds[i], &p);
		printf("GPU%u: %s | driver: %s / %s | api %u.%u.%u | %04x:%04x | LUIDValid %u\n", i, p.properties.deviceName,
		       drv.driverName, drv.driverInfo, VK_API_VERSION_MAJOR(p.properties.apiVersion),
		       VK_API_VERSION_MINOR(p.properties.apiVersion), VK_API_VERSION_PATCH(p.properties.apiVersion),
		       p.properties.vendorID, p.properties.deviceID, id.deviceLUIDValid);
	}
	VkPhysicalDevice pd = pds[0];

	WNDCLASSA wc = {CS_OWNDC, wndproc, 0, 0, GetModuleHandleA(NULL), NULL, LoadCursor(NULL, IDC_ARROW), NULL, NULL, "vkbench"};
	RegisterClassA(&wc);
	RECT rc = {0, 0, W, H}; AdjustWindowRect(&rc, WS_OVERLAPPEDWINDOW, FALSE);
	HWND hwnd = CreateWindowA("vkbench", "vkbench (Vulkan)", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 40, 40,
				  rc.right - rc.left, rc.bottom - rc.top, NULL, NULL, wc.hInstance, NULL);
	MSG msg; while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }

	VkSurfaceKHR surf;
	VkWin32SurfaceCreateInfoKHR sci = {VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR, .hinstance = wc.hInstance, .hwnd = hwnd};
	CK(vkCreateWin32SurfaceKHR(inst, &sci, NULL, &surf));

	uint32_t nq = 0; vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, NULL);
	VkQueueFamilyProperties qf[16]; if (nq > 16) nq = 16; vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qf);
	uint32_t fam = UINT32_MAX;
	for (uint32_t i = 0; i < nq; i++) {
		VkBool32 sup = 0; vkGetPhysicalDeviceSurfaceSupportKHR(pd, i, surf, &sup);
		if ((qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && sup) { fam = i; break; }
	}
	if (fam == UINT32_MAX) { printf("no graphics+present queue\n"); return 1; }

	float prio = 1.0f;
	VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = fam, .queueCount = 1, .pQueuePriorities = &prio};
	const char *dext[] = {"VK_KHR_swapchain"};
	VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci, .enabledExtensionCount = 1, .ppEnabledExtensionNames = dext};
	VkDevice dev; CK(vkCreateDevice(pd, &dci, NULL, &dev));
	DL(vkGetDeviceQueue); DL(vkCreateSwapchainKHR); DL(vkGetSwapchainImagesKHR); DL(vkCreateImageView); DL(vkCreateRenderPass);
	DL(vkCreateFramebuffer); DL(vkCreateShaderModule); DL(vkCreatePipelineLayout); DL(vkCreateGraphicsPipelines);
	DL(vkCreateCommandPool); DL(vkAllocateCommandBuffers); DL(vkCreateSemaphore); DL(vkCreateFence); DL(vkWaitForFences);
	DL(vkResetFences); DL(vkAcquireNextImageKHR); DL(vkBeginCommandBuffer); DL(vkCmdBeginRenderPass); DL(vkCmdBindPipeline);
	DL(vkCmdPushConstants); DL(vkCmdDraw); DL(vkCmdEndRenderPass); DL(vkEndCommandBuffer); DL(vkQueueSubmit);
	DL(vkQueuePresentKHR); DL(vkDeviceWaitIdle); DL(vkResetCommandBuffer); DL(vkCmdSetViewport); DL(vkCmdSetScissor);
	VkQueue q; vkGetDeviceQueue(dev, fam, 0, &q);

	VkSurfaceCapabilitiesKHR caps; CK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surf, &caps));
	uint32_t nf = 0; vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surf, &nf, NULL);
	VkSurfaceFormatKHR fmts[64]; if (nf > 64) nf = 64; vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surf, &nf, fmts);
	VkSurfaceFormatKHR fmt = fmts[0];
	for (uint32_t i = 0; i < nf; i++) if (fmts[i].format == VK_FORMAT_B8G8R8A8_UNORM) fmt = fmts[i];
	uint32_t npm = 0; vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surf, &npm, NULL);
	VkPresentModeKHR pms[16]; if (npm > 16) npm = 16; vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surf, &npm, pms);
	VkPresentModeKHR want = !strcmp(mode, "fifo") ? VK_PRESENT_MODE_FIFO_KHR : !strcmp(mode, "mailbox") ? VK_PRESENT_MODE_MAILBOX_KHR : VK_PRESENT_MODE_IMMEDIATE_KHR;
	VkPresentModeKHR pm = VK_PRESENT_MODE_FIFO_KHR;
	printf("present modes:");
	for (uint32_t i = 0; i < npm; i++) { printf(" %d", pms[i]); if (pms[i] == want) pm = want; }
	printf(" -> using %d; format %d; extent %ux%u; images min %u\n", pm, fmt.format, caps.currentExtent.width, caps.currentExtent.height, caps.minImageCount);
	VkExtent2D ext = caps.currentExtent;
	if (ext.width == UINT32_MAX) { ext.width = W; ext.height = H; }

	uint32_t nimg = caps.minImageCount + 1;
	if (caps.maxImageCount && nimg > caps.maxImageCount) nimg = caps.maxImageCount;
	VkSwapchainCreateInfoKHR swci = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = surf, .minImageCount = nimg,
		.imageFormat = fmt.format, .imageColorSpace = fmt.colorSpace, .imageExtent = ext, .imageArrayLayers = 1,
		.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, .preTransform = caps.currentTransform,
		.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, .presentMode = pm, .clipped = VK_TRUE};
	VkSwapchainKHR sc; CK(vkCreateSwapchainKHR(dev, &swci, NULL, &sc));
	CK(vkGetSwapchainImagesKHR(dev, sc, &nimg, NULL));
	VkImage imgs[16]; if (nimg > 16) nimg = 16; CK(vkGetSwapchainImagesKHR(dev, sc, &nimg, imgs));

	VkAttachmentDescription att = {0, fmt.format, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_STORE,
		VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR};
	VkAttachmentReference ar = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
	VkSubpassDescription sp = {0, VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &ar};
	VkSubpassDependency dep = {VK_SUBPASS_EXTERNAL, 0, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
		0, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, 0};
	VkRenderPassCreateInfo rpci = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &att,
		.subpassCount = 1, .pSubpasses = &sp, .dependencyCount = 1, .pDependencies = &dep};
	VkRenderPass rp; CK(vkCreateRenderPass(dev, &rpci, NULL, &rp));
	VkFramebuffer fbs[16];
	for (uint32_t i = 0; i < nimg; i++) {
		VkImageViewCreateInfo vci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = imgs[i], .viewType = VK_IMAGE_VIEW_TYPE_2D,
			.format = fmt.format, .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
		VkImageView v; CK(vkCreateImageView(dev, &vci, NULL, &v));
		VkFramebufferCreateInfo fci = {VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp, .attachmentCount = 1,
			.pAttachments = &v, .width = ext.width, .height = ext.height, .layers = 1};
		CK(vkCreateFramebuffer(dev, &fci, NULL, &fbs[i]));
	}
	VkShaderModuleCreateInfo smv = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(bench_vert_spv), .pCode = bench_vert_spv};
	VkShaderModuleCreateInfo smf = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof(bench_frag_spv), .pCode = bench_frag_spv};
	VkShaderModule vs, fs; CK(vkCreateShaderModule(dev, &smv, NULL, &vs)); CK(vkCreateShaderModule(dev, &smf, NULL, &fs));
	VkPushConstantRange pcr = {VK_SHADER_STAGE_FRAGMENT_BIT, 0, 8};
	VkPipelineLayoutCreateInfo plci = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr};
	VkPipelineLayout pl; CK(vkCreatePipelineLayout(dev, &plci, NULL, &pl));
	VkPipelineShaderStageCreateInfo st[2] = {
		{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main"},
		{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main"}};
	VkPipelineVertexInputStateCreateInfo vi = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
	VkPipelineInputAssemblyStateCreateInfo ia = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
	VkPipelineViewportStateCreateInfo vp = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1};
	VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .cullMode = VK_CULL_MODE_NONE, .lineWidth = 1.0f};
	VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
	VkPipelineColorBlendAttachmentState cba = {.colorWriteMask = 0xf};
	VkPipelineColorBlendStateCreateInfo cb = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &cba};
	VkDynamicState dyns[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
	VkPipelineDynamicStateCreateInfo dy = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = dyns};
	VkGraphicsPipelineCreateInfo gpci = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = st, .pVertexInputState = &vi,
		.pInputAssemblyState = &ia, .pViewportState = &vp, .pRasterizationState = &rs, .pMultisampleState = &ms, .pColorBlendState = &cb,
		.pDynamicState = &dy, .layout = pl, .renderPass = rp};
	VkPipeline pipe; CK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL, &pipe));

	enum { FIF = 2 };
	VkCommandPoolCreateInfo cpci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = fam};
	VkCommandPool cp; CK(vkCreateCommandPool(dev, &cpci, NULL, &cp));
	VkCommandBufferAllocateInfo cbai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = FIF};
	VkCommandBuffer cbs[FIF]; CK(vkAllocateCommandBuffers(dev, &cbai, cbs));
	VkSemaphore acq[FIF], done[16]; VkFence fen[FIF];
	VkSemaphoreCreateInfo sei = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
	VkFenceCreateInfo fei = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT};
	for (int i = 0; i < FIF; i++) { CK(vkCreateSemaphore(dev, &sei, NULL, &acq[i])); CK(vkCreateFence(dev, &fei, NULL, &fen[i])); }
	for (uint32_t i = 0; i < nimg; i++) CK(vkCreateSemaphore(dev, &sei, NULL, &done[i]));

	double t0 = now(), tl = t0; long frames = 0, fl = 0, fi = 0; double best = 0, sum = 0; int nsec = 0;
	while (!quit && now() - t0 < seconds) {
		while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
		int f = fi % FIF;
		CK(vkWaitForFences(dev, 1, &fen[f], VK_TRUE, UINT64_MAX));
		uint32_t ii;
		VkResult ar_ = vkAcquireNextImageKHR(dev, sc, UINT64_MAX, acq[f], VK_NULL_HANDLE, &ii);
		if (ar_ != VK_SUCCESS && ar_ != VK_SUBOPTIMAL_KHR) { printf("acquire -> %d\n", ar_); break; }
		CK(vkResetFences(dev, 1, &fen[f]));
		VkCommandBuffer c = cbs[f];
		CK(vkResetCommandBuffer(c, 0));
		VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
		CK(vkBeginCommandBuffer(c, &bi));
		VkRenderPassBeginInfo rbi = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp, .framebuffer = fbs[ii], .renderArea = {{0, 0}, ext}};
		vkCmdBeginRenderPass(c, &rbi, VK_SUBPASS_CONTENTS_INLINE);
		vkCmdBindPipeline(c, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
		VkViewport v = {0, 0, (float)ext.width, (float)ext.height, 0, 1}; VkRect2D s = {{0, 0}, ext};
		vkCmdSetViewport(c, 0, 1, &v); vkCmdSetScissor(c, 0, 1, &s);
		struct { float t; int it; } pc = {(float)(now() - t0), iters};
		vkCmdPushConstants(c, pl, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 8, &pc);
		vkCmdDraw(c, 3, 1, 0, 0);
		vkCmdEndRenderPass(c);
		CK(vkEndCommandBuffer(c));
		VkPipelineStageFlags ws = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
		VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &acq[f], .pWaitDstStageMask = &ws,
			.commandBufferCount = 1, .pCommandBuffers = &c, .signalSemaphoreCount = 1, .pSignalSemaphores = &done[ii]};
		CK(vkQueueSubmit(q, 1, &si, fen[f]));
		VkPresentInfoKHR pi = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1, .pWaitSemaphores = &done[ii], .swapchainCount = 1, .pSwapchains = &sc, .pImageIndices = &ii};
		VkResult pr = vkQueuePresentKHR(q, &pi);
		if (pr != VK_SUCCESS && pr != VK_SUBOPTIMAL_KHR) { printf("present -> %d\n", pr); break; }
		frames++; fi++;
		double t = now();
		if (t - tl >= 1.0) {
			double fps = (frames - fl) / (t - tl);
			printf("fps %.1f\n", fps);
			if (nsec > 0) { sum += fps; if (fps > best) best = fps; }  /* skip the warm-up second */
			nsec++; tl = t; fl = frames;
		}
	}
	vkDeviceWaitIdle(dev);
	printf("RESULT vulkan iters=%d %ux%u mode=%d avg_fps=%.1f (steady %d s) best=%.1f frames=%ld\n", iters, ext.width, ext.height, pm,
	       nsec > 1 ? sum / (nsec - 1) : 0.0, nsec > 1 ? nsec - 1 : 0, best, frames);
	return 0;
}
