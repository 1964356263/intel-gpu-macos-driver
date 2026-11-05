// SPDX-License-Identifier: MIT
// wsitest: a Vulkan window app for ANV's VK_EXT_metal_surface IOSurface swapchain (Mesa patch 0019).
// Draws without shaders (render-pass clear + vkCmdClearAttachments): a background whose color encodes the frame number,
// a moving white bar, and 24 squares holding the frame number's bits. Measures fps per present mode and, at the end,
// checks the IOSurface the window shows (a CPU lock = the kernel's page-off of the VRAM backing) holds the last frame.
//   open -n wsitest.app --args --icd <icd.json> --mode immediate|mailbox|fifo --seconds 5 --images 3 --out /tmp/x.txt
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#define VK_USE_PLATFORM_METAL_EXT 1
#include <vulkan/vulkan.h>

static FILE *out;
#define LOG(...) do { fprintf(out, __VA_ARGS__); fprintf(out, "\n"); fflush(out); } while (0)
#define CK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS && r_ != VK_SUBOPTIMAL_KHR) { LOG("FAIL %s = %d (line %d)", #x, r_, __LINE__); exit(2); } } while (0)

static PFN_vkGetInstanceProcAddr gipa;
#define IFN(name) PFN_##name name = (PFN_##name)gipa(inst, #name)
static NSString *g_mode = @"immediate";
static double g_seconds = 5;
static uint32_t g_images = 3, g_w = 1280, g_h = 720;
static int g_bench;
static CAMetalLayer *g_layer;
static double now_s(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }

static void bg_color(uint32_t f, float c[4]) { c[0] = (f % 7) / 6.0f; c[1] = ((f / 7) % 5) / 4.0f; c[2] = 0.25f + 0.5f * ((f / 35) % 2); c[3] = 1; }
static uint8_t u8(float v) { return (uint8_t)(v * 255.0f + 0.5f); }

static void render_thread(void)
{
   void *lib = dlopen("/usr/local/lib/libvulkan.1.dylib", RTLD_NOW | RTLD_LOCAL);
   if (!lib) { LOG("FAIL dlopen loader: %s", dlerror()); exit(2); }
   gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
   VkInstance inst = VK_NULL_HANDLE;
   IFN(vkCreateInstance);
   const char *iext[] = { "VK_KHR_surface", "VK_EXT_metal_surface" };
   VkApplicationInfo ai = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3, .pApplicationName = "wsitest" };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai, .enabledExtensionCount = 2, .ppEnabledExtensionNames = iext };
   CK(vkCreateInstance(&ici, NULL, &inst));
   IFN(vkEnumeratePhysicalDevices); IFN(vkGetPhysicalDeviceProperties2); IFN(vkCreateMetalSurfaceEXT); IFN(vkCreateDevice);
   IFN(vkGetDeviceProcAddr); IFN(vkGetPhysicalDeviceSurfaceCapabilitiesKHR); IFN(vkGetPhysicalDeviceSurfaceFormatsKHR);
   IFN(vkGetPhysicalDeviceSurfacePresentModesKHR); IFN(vkGetPhysicalDeviceSurfaceSupportKHR); IFN(vkGetPhysicalDeviceFeatures2);
   uint32_t n = 4; VkPhysicalDevice pds[4];
   CK(vkEnumeratePhysicalDevices(inst, &n, pds));
   VkPhysicalDevice pd = pds[0];
   VkPhysicalDeviceDriverProperties drv = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
   VkPhysicalDeviceProperties2 pp = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &drv };
   vkGetPhysicalDeviceProperties2(pd, &pp);
   VkPhysicalDeviceFeatures2 feat = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 };
   vkGetPhysicalDeviceFeatures2(pd, &feat);
   LOG("device: %s, driver %s %s, maxDrawIndirectCount %u, multiDrawIndirect %u, drawIndirectFirstInstance %u", pp.properties.deviceName,
       drv.driverName, drv.driverInfo, pp.properties.limits.maxDrawIndirectCount, feat.features.multiDrawIndirect, feat.features.drawIndirectFirstInstance);

   VkSurfaceKHR surf;
   VkMetalSurfaceCreateInfoEXT msci = { .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT, .pLayer = g_layer };
   CK(vkCreateMetalSurfaceEXT(inst, &msci, NULL, &surf));
   VkBool32 sup = 0; CK(vkGetPhysicalDeviceSurfaceSupportKHR(pd, 0, surf, &sup));
   VkSurfaceCapabilitiesKHR caps; CK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surf, &caps));
   uint32_t nf = 16; VkSurfaceFormatKHR fmts[16]; CK(vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surf, &nf, fmts));
   uint32_t nm = 8; VkPresentModeKHR modes[8]; CK(vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surf, &nm, modes));
   LOG("surface: supported %u, extent %ux%u, images %u..%u, usage 0x%x, %u formats (first %d/%d), %u present modes",
       sup, caps.currentExtent.width, caps.currentExtent.height, caps.minImageCount, caps.maxImageCount, caps.supportedUsageFlags, nf,
       fmts[0].format, fmts[0].colorSpace, nm);
   VkPresentModeKHR pm = [g_mode isEqualToString:@"fifo"] ? VK_PRESENT_MODE_FIFO_KHR :
                         [g_mode isEqualToString:@"mailbox"] ? VK_PRESENT_MODE_MAILBOX_KHR : VK_PRESENT_MODE_IMMEDIATE_KHR;

   float prio = 1;
   VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio };
   VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .dynamicRendering = 1, .synchronization2 = 1 };
   const char *dext[] = { "VK_KHR_swapchain" };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &f13, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
                              .enabledExtensionCount = 1, .ppEnabledExtensionNames = dext };
   VkDevice dev; CK(vkCreateDevice(pd, &dci, NULL, &dev));
#define DFN(name) PFN_##name name = (PFN_##name)vkGetDeviceProcAddr(dev, #name)
   DFN(vkGetDeviceQueue); DFN(vkCreateSwapchainKHR); DFN(vkGetSwapchainImagesKHR); DFN(vkAcquireNextImageKHR); DFN(vkQueuePresentKHR);
   DFN(vkCreateCommandPool); DFN(vkAllocateCommandBuffers); DFN(vkBeginCommandBuffer); DFN(vkEndCommandBuffer); DFN(vkCmdPipelineBarrier2);
   DFN(vkCmdBeginRendering); DFN(vkCmdEndRendering); DFN(vkCmdClearAttachments); DFN(vkQueueSubmit); DFN(vkCreateSemaphore);
   DFN(vkCreateFence); DFN(vkWaitForFences); DFN(vkResetFences); DFN(vkCreateImageView); DFN(vkDeviceWaitIdle); DFN(vkResetCommandBuffer);
   DFN(vkDestroySwapchainKHR); DFN(vkDestroyImageView);
   VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);

   VkSwapchainCreateInfoKHR sci = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = surf,
      .minImageCount = MAX(g_images, caps.minImageCount), .imageFormat = VK_FORMAT_B8G8R8A8_UNORM, .imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
      .imageExtent = caps.currentExtent, .imageArrayLayers = 1, .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
      .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE, .preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
      .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, .presentMode = pm, .clipped = VK_TRUE };
   VkSwapchainKHR sc; double t0 = now_s(); CK(vkCreateSwapchainKHR(dev, &sci, NULL, &sc));
   uint32_t ni = 8; VkImage imgs[8]; CK(vkGetSwapchainImagesKHR(dev, sc, &ni, imgs));
   LOG("swapchain: %ux%u, %u images, mode %s, created in %.1f ms", sci.imageExtent.width, sci.imageExtent.height, ni, g_mode.UTF8String, (now_s() - t0) * 1e3);
   VkImageView views[8];
   for (uint32_t i = 0; i < ni; i++) {
      VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = imgs[i], .viewType = VK_IMAGE_VIEW_TYPE_2D,
         .format = sci.imageFormat, .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
      CK(vkCreateImageView(dev, &vci, NULL, &views[i]));
   }
   VkCommandPool pool; VkCommandPoolCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
   CK(vkCreateCommandPool(dev, &cpci, NULL, &pool));
   enum { FIF = 2 };
   VkCommandBuffer cbs[FIF]; VkCommandBufferAllocateInfo cbai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = FIF };
   CK(vkAllocateCommandBuffers(dev, &cbai, cbs));
   VkSemaphore acq[FIF], rel[8]; VkFence fen[FIF];
   VkSemaphoreCreateInfo semci = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
   VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT };
   for (int i = 0; i < FIF; i++) { CK(vkCreateSemaphore(dev, &semci, NULL, &acq[i])); CK(vkCreateFence(dev, &fci, NULL, &fen[i])); }
   for (uint32_t i = 0; i < ni; i++) CK(vkCreateSemaphore(dev, &semci, NULL, &rel[i]));


   if (g_bench) {
      // Minecraft's last step: vkCmdBlitImage of its RGBA8 target (optimal, compressed when the driver can) into the
      // B8G8R8A8 swapchain image (TRANSFER_DST only). Timed against the same blit into an optimal image and into a
      // private linear image, with GPU timestamps around each.
      DFN(vkCreateImage); DFN(vkGetImageMemoryRequirements); DFN(vkAllocateMemory); DFN(vkBindImageMemory);
      DFN(vkCreateQueryPool); DFN(vkCmdWriteTimestamp); DFN(vkGetQueryPoolResults); DFN(vkCmdBlitImage);
      DFN(vkCmdClearColorImage); DFN(vkCmdResetQueryPool);
      VkPhysicalDeviceMemoryProperties mp; IFN(vkGetPhysicalDeviceMemoryProperties); vkGetPhysicalDeviceMemoryProperties(pd, &mp);
      const uint32_t W = sci.imageExtent.width, H = sci.imageExtent.height;
      VkImage src, dtile, dlin, dunc; VkDeviceMemory m;
      struct { VkImage *img; VkFormat fmt; VkImageTiling til; VkImageUsageFlags use; int skip_compressed; } mk[4] = {
         { &src, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT },
         { &dtile, VK_FORMAT_B8G8R8A8_UNORM, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT },
         { &dlin, VK_FORMAT_B8G8R8A8_UNORM, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT },
         { &dunc, VK_FORMAT_B8G8R8A8_UNORM, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, 1 } };
      for (int i = 0; i < 4; i++) {
         VkImageCreateInfo ic = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = mk[i].fmt,
            .extent = { W, H, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = 1, .tiling = mk[i].til, .usage = mk[i].use };
         CK(vkCreateImage(dev, &ic, NULL, mk[i].img));
         VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, *mk[i].img, &mr);
         uint32_t t = mk[i].skip_compressed ? 1 : 0; for (; t < mp.memoryTypeCount; t++) if ((mr.memoryTypeBits >> t & 1) && (mp.memoryTypes[t].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) break;
         VkMemoryAllocateInfo ma = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
         CK(vkAllocateMemory(dev, &ma, NULL, &m)); CK(vkBindImageMemory(dev, *mk[i].img, m, 0));
         LOG("bench image %d: %s, memory type %u (bits 0x%x)", i, mk[i].til == VK_IMAGE_TILING_LINEAR ? "linear" : "optimal", t, mr.memoryTypeBits);
      }
      VkQueryPool qp; VkQueryPoolCreateInfo qpi = { .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = 2 * 8 };
      CK(vkCreateQueryPool(dev, &qpi, NULL, &qp));
      double sum[5] = {0}; uint32_t nsum = 0; const double tp = pp.properties.limits.timestampPeriod;
      const VkImageSubresourceRange rr = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
      const VkImageBlit bl = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .srcOffsets = { {0,0,0}, {(int32_t)W,(int32_t)H,1} },
                               .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .dstOffsets = { {0,0,0}, {(int32_t)W,(int32_t)H,1} } };
      double start = now_s(); uint32_t frame = 0;
      while (now_s() - start < g_seconds) {
         const int s = frame % FIF;
         CK(vkWaitForFences(dev, 1, &fen[s], VK_TRUE, UINT64_MAX)); CK(vkResetFences(dev, 1, &fen[s]));
         if (frame >= FIF) {
            uint64_t ts[6];
            if (vkGetQueryPoolResults(dev, qp, s * 8, 6, sizeof ts, ts, 8, VK_QUERY_RESULT_64_BIT) == VK_SUCCESS && frame > 20) {
               for (int k = 0; k < 5; k++) sum[k] += (ts[k + 1] - ts[k]) * tp / 1000.0;
               nsum++;
            }
         }
         uint32_t idx; CK(vkAcquireNextImageKHR(dev, sc, UINT64_MAX, acq[s], VK_NULL_HANDLE, &idx));
         VkCommandBuffer cb = cbs[s]; CK(vkResetCommandBuffer(cb, 0));
         VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
         CK(vkBeginCommandBuffer(cb, &bi));
         vkCmdResetQueryPool(cb, qp, s * 8, 8);
         VkImageMemoryBarrier2 b[5] = {
            { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .dstStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
              .dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .image = src, .subresourceRange = rr },
            { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .dstStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
              .dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .image = imgs[idx], .subresourceRange = rr },
            { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .dstStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
              .dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .image = dtile, .subresourceRange = rr },
            { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .dstStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
              .dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .image = dlin, .subresourceRange = rr },
            { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .dstStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
              .dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .image = dunc, .subresourceRange = rr } };
         VkDependencyInfo di = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 5, .pImageMemoryBarriers = b };
         vkCmdPipelineBarrier2(cb, &di);
         vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, qp, s * 8 + 0);
         float c[4]; bg_color(frame, c);
         VkClearColorValue cv = { .float32 = { c[0], c[1], c[2], 1 } };
         vkCmdClearColorImage(cb, src, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &cv, 1, &rr);
         VkImageMemoryBarrier2 sb = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, .srcStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
            .srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT, .dstStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT, .dstAccessMask = VK_ACCESS_2_TRANSFER_READ_BIT,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, .image = src, .subresourceRange = rr };
         VkDependencyInfo sdi = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &sb };
         vkCmdPipelineBarrier2(cb, &sdi);
         vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, qp, s * 8 + 1);
         vkCmdBlitImage(cb, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, imgs[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bl, VK_FILTER_NEAREST);
         VkMemoryBarrier2 mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2, .srcStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT, .srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT,
            .dstStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT, .dstAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT };
         VkDependencyInfo mdi = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .memoryBarrierCount = 1, .pMemoryBarriers = &mb };
         vkCmdPipelineBarrier2(cb, &mdi);
         vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, qp, s * 8 + 2);
         vkCmdBlitImage(cb, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dtile, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bl, VK_FILTER_NEAREST);
         vkCmdPipelineBarrier2(cb, &mdi);
         vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, qp, s * 8 + 3);
         vkCmdBlitImage(cb, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dlin, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bl, VK_FILTER_NEAREST);
         vkCmdPipelineBarrier2(cb, &mdi);
         vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, qp, s * 8 + 4);
         vkCmdBlitImage(cb, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dunc, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bl, VK_FILTER_NEAREST);
         vkCmdPipelineBarrier2(cb, &mdi);
         vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, qp, s * 8 + 5);
         VkImageMemoryBarrier2 pb = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, .srcStageMask = VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
            .srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT, .dstStageMask = VK_PIPELINE_STAGE_2_NONE,
            .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, .image = imgs[idx], .subresourceRange = rr };
         VkDependencyInfo pdi = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &pb };
         vkCmdPipelineBarrier2(cb, &pdi);
         CK(vkEndCommandBuffer(cb));
         VkPipelineStageFlags ws = VK_PIPELINE_STAGE_TRANSFER_BIT;
         VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &acq[s], .pWaitDstStageMask = &ws,
            .commandBufferCount = 1, .pCommandBuffers = &cb, .signalSemaphoreCount = 1, .pSignalSemaphores = &rel[idx] };
         CK(vkQueueSubmit(q, 1, &si, fen[s]));
         VkPresentInfoKHR pi = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1, .pWaitSemaphores = &rel[idx],
            .swapchainCount = 1, .pSwapchains = &sc, .pImageIndices = &idx };
         CK(vkQueuePresentKHR(q, &pi));
         frame++;
      }
      CK(vkDeviceWaitIdle(dev));
      LOG("BENCH %ux%u over %u frames (%.0f fps): clear RGBA8 optimal %.1f us; blit RGBA8 optimal -> B8G8R8A8 swapchain (linear, IOSurface VRAM) %.1f us, "
          "-> B8G8R8A8 optimal compressed %.1f us, -> B8G8R8A8 linear private %.1f us, -> B8G8R8A8 optimal uncompressed %.1f us",
          W, H, nsum, frame / (now_s() - start), sum[0] / nsum, sum[1] / nsum, sum[2] / nsum, sum[3] / nsum, sum[4] / nsum);
      LOG("done"); exit(0);
   }
   const uint32_t W = sci.imageExtent.width, H = sci.imageExtent.height;
   double start = now_s(), last_report = start, acq_t = 0, pres_t = 0, max_frame = 0, prev = start;
   uint32_t frame = 0, frames_at_report = 0, suboptimal = 0;
   while (now_s() - start < g_seconds) {
      const int s = frame % FIF;
      CK(vkWaitForFences(dev, 1, &fen[s], VK_TRUE, UINT64_MAX)); CK(vkResetFences(dev, 1, &fen[s]));
      uint32_t idx; double a0 = now_s();
      VkResult ar = vkAcquireNextImageKHR(dev, sc, UINT64_MAX, acq[s], VK_NULL_HANDLE, &idx); CK(ar);
      acq_t += now_s() - a0; if (ar == VK_SUBOPTIMAL_KHR) suboptimal++;
      VkCommandBuffer cb = cbs[s];
      CK(vkResetCommandBuffer(cb, 0));
      VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
      CK(vkBeginCommandBuffer(cb, &bi));
      VkImageMemoryBarrier2 b = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2, .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
         .dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, .dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
         .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .image = imgs[idx],
         .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
      VkDependencyInfo di = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &b };
      vkCmdPipelineBarrier2(cb, &di);
      float c[4]; bg_color(frame, c);
      VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO, .imageView = views[idx],
         .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
         .clearValue.color.float32 = { c[0], c[1], c[2], c[3] } };
      VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { {0, 0}, {W, H} }, .layerCount = 1,
         .colorAttachmentCount = 1, .pColorAttachments = &att };
      vkCmdBeginRendering(cb, &ri);
      // moving bar
      VkClearAttachment ca = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .colorAttachment = 0, .clearValue.color.float32 = { 1, 1, 1, 1 } };
      uint32_t bw = W / 16, bx = (frame * 8) % (W - bw);
      VkClearRect cr = { .rect = { { (int32_t)bx, H / 4 }, { bw, H / 2 } }, .baseArrayLayer = 0, .layerCount = 1 };
      vkCmdClearAttachments(cb, 1, &ca, 1, &cr);
      // frame number bits: 24 squares along the top, white = 1, black = 0
      uint32_t sq = W / 32;
      for (int bit = 0; bit < 24; bit++) {
         float v = (frame >> bit) & 1 ? 1.0f : 0.0f;
         VkClearAttachment cb2 = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .colorAttachment = 0, .clearValue.color.float32 = { v, v, v, 1 } };
         VkClearRect r2 = { .rect = { { (int32_t)(sq / 2 + bit * sq), (int32_t)(sq / 2) }, { sq * 3 / 4, sq * 3 / 4 } }, .baseArrayLayer = 0, .layerCount = 1 };
         vkCmdClearAttachments(cb, 1, &cb2, 1, &r2);
      }
      vkCmdEndRendering(cb);
      b.srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT; b.srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT;
      b.dstStageMask = VK_PIPELINE_STAGE_2_NONE; b.dstAccessMask = 0;
      b.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL; b.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
      vkCmdPipelineBarrier2(cb, &di);
      CK(vkEndCommandBuffer(cb));
      VkPipelineStageFlags ws = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
      VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &acq[s], .pWaitDstStageMask = &ws,
         .commandBufferCount = 1, .pCommandBuffers = &cb, .signalSemaphoreCount = 1, .pSignalSemaphores = &rel[idx] };
      CK(vkQueueSubmit(q, 1, &si, fen[s]));
      VkPresentInfoKHR pi = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1, .pWaitSemaphores = &rel[idx],
         .swapchainCount = 1, .pSwapchains = &sc, .pImageIndices = &idx };
      double p0 = now_s(); VkResult pr = vkQueuePresentKHR(q, &pi); CK(pr); pres_t += now_s() - p0;
      if (pr == VK_SUBOPTIMAL_KHR) suboptimal++;
      double t = now_s(); if (frame > 10 && t - prev > max_frame) max_frame = t - prev; prev = t;
      frame++;
      if (t - last_report >= 1.0) { LOG("  %.0f fps", (frame - frames_at_report) / (t - last_report)); last_report = t; frames_at_report = frame; }
   }
   double el = now_s() - start;
   CK(vkDeviceWaitIdle(dev));
   LOG("RESULT mode %s: %u frames in %.2f s = %.1f fps; acquire %.3f ms/frame, present %.3f ms/frame, worst frame %.2f ms, suboptimal %u",
       g_mode.UTF8String, frame, el, frame / el, acq_t / frame * 1e3, pres_t / frame * 1e3, max_frame * 1e3, suboptimal);

   // what the window shows: the contents of the WSI's sublayer of our CAMetalLayer
   usleep(200 * 1000);
   const uint32_t last = frame - 1;
   __block IOSurfaceRef shown = NULL;
   dispatch_sync(dispatch_get_main_queue(), ^{
      for (CALayer *l in g_layer.sublayers) { id c = l.contents; if (c && CFGetTypeID((__bridge CFTypeRef)c) == IOSurfaceGetTypeID()) { shown = (IOSurfaceRef)CFRetain((__bridge CFTypeRef)c); LOG("contents layer %s, frame %.0fx%.0f, scale %.1f", l.name.UTF8String, l.frame.size.width, l.frame.size.height, l.contentsScale); } }
   });
   if (!shown) { LOG("FAIL no IOSurface in the layer"); exit(3); }
   double l0 = now_s();
   IOSurfaceLock(shown, kIOSurfaceLockReadOnly, NULL);
   double lock_ms = (now_s() - l0) * 1e3;
   const uint8_t *px = IOSurfaceGetBaseAddress(shown); size_t row = IOSurfaceGetBytesPerRow(shown);
   uint32_t sq = W / 32, got = 0;
   for (int bit = 0; bit < 24; bit++) {
      const uint8_t *p = px + (size_t)(sq / 2 + sq * 3 / 8) * row + (size_t)(sq / 2 + bit * sq + sq * 3 / 8) * 4;
      if (p[0] > 128) got |= 1u << bit;
   }
   float c[4]; bg_color(got, c);
   const uint8_t *bgp = px + (size_t)(H - 4) * row + 4 * 4;  // bottom-left: background
   int bg_ok = abs(bgp[2] - u8(c[0])) <= 1 && abs(bgp[1] - u8(c[1])) <= 1 && abs(bgp[0] - u8(c[2])) <= 1;
   uint32_t bw = W / 16, bx = (got * 8) % (W - bw);
   const uint8_t *barp = px + (size_t)(H / 2) * row + (size_t)(bx + bw / 2) * 4;
   int bar_ok = barp[0] == 255 && barp[1] == 255 && barp[2] == 255;
   LOG("IOSurface %u %zux%zu row %zu: CPU lock %.2f ms; shows frame %u (last presented %u), background %s (%u,%u,%u), bar %s",
       IOSurfaceGetID(shown), IOSurfaceGetWidth(shown), IOSurfaceGetHeight(shown), row, lock_ms, got, last,
       bg_ok ? "OK" : "WRONG", bgp[2], bgp[1], bgp[0], bar_ok ? "OK" : "WRONG");
   IOSurfaceUnlock(shown, kIOSurfaceLockReadOnly, NULL);
   LOG("%s", (got == last && bg_ok && bar_ok) ? "VERIFY PASS" : "VERIFY FAIL");
   CFRelease(shown);
   LOG("holding the last frame (screenshot window)");
   sleep(3);
   for (uint32_t i = 0; i < ni; i++) vkDestroyImageView(dev, views[i], NULL);
   vkDestroySwapchainKHR(dev, sc, NULL);
   LOG("done");
   exit(0);
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@end
@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {
   self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, g_w, g_h)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
   self.window.title = @"wsitest (ANV IOSurface WSI)";
   NSView *v = self.window.contentView;
   g_layer = [CAMetalLayer layer];
   v.layer = g_layer; v.wantsLayer = YES;
   g_layer.contentsScale = self.window.backingScaleFactor;
   [self.window makeKeyAndOrderFront:nil];
   [NSApp activateIgnoringOtherApps:YES];
   [[[NSThread alloc] initWithBlock:^{ render_thread(); }] start];
}
@end

int main(int argc, const char **argv)
{
   const char *outp = "/tmp/wsitest.txt";
   for (int i = 1; i + 1 < argc; i += 2) {
      if (!strcmp(argv[i], "--icd")) setenv("VK_DRIVER_FILES", argv[i + 1], 1);
      else if (!strcmp(argv[i], "--mode")) g_mode = [NSString stringWithUTF8String:argv[i + 1]];
      else if (!strcmp(argv[i], "--seconds")) g_seconds = atof(argv[i + 1]);
      else if (!strcmp(argv[i], "--images")) g_images = atoi(argv[i + 1]);
      else if (!strcmp(argv[i], "--out")) outp = argv[i + 1];
      else if (!strcmp(argv[i], "--size")) sscanf(argv[i + 1], "%ux%u", &g_w, &g_h);
      else if (!strcmp(argv[i], "--bench")) g_bench = !strcmp(argv[i + 1], "blit");
      else if (!strcmp(argv[i], "--setenv")) putenv(strdup(argv[i + 1]));
   }
   out = fopen(outp, "w"); if (!out) out = stderr;
   @autoreleasepool {
      NSApplication *app = [NSApplication sharedApplication];
      [app setActivationPolicy:NSApplicationActivationPolicyRegular];
      AppDelegate *d = [AppDelegate new]; app.delegate = d;
      [app run];
   }
   return 0;
}
