// SPDX-License-Identifier: MIT
// vkplaced: VK_EXT_map_memory_placed on ANV/xemac (what 32-bit DXVK under WoW64 does): map a host-visible allocation at
// an address we reserved, write through it, copy it on the GPU into a second buffer mapped the normal way, compare;
// unmap with VK_MEMORY_UNMAP_RESERVE_BIT_EXT and check the range is reserved again; repeat for VRAM (BAR) and system
// memory types. Through the Khronos loader; VK_DRIVER_FILES picks the ICD.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <vulkan/vulkan.h>
static PFN_vkGetInstanceProcAddr gipa; static PFN_vkGetDeviceProcAddr gdpa; static VkInstance inst; static VkDevice dev;
#define I(n) PFN_##n n = (PFN_##n)gipa(inst, #n)
#define D(n) PFN_##n n = (PFN_##n)gdpa(dev, #n)
#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d\n", #x, r_); return 1; } } while (0)
int main(void) {
   void *lib = dlopen("/usr/local/lib/libvulkan.1.dylib", RTLD_NOW); if (!lib) return 1;
   gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
   I(vkCreateInstance);
   VkApplicationInfo ai = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai };
   CK(vkCreateInstance(&ici, NULL, &inst));
   I(vkEnumeratePhysicalDevices); I(vkCreateDevice); I(vkGetPhysicalDeviceMemoryProperties); I(vkGetPhysicalDeviceProperties2);
   uint32_t n = 1; VkPhysicalDevice pd; vkEnumeratePhysicalDevices(inst, &n, &pd);
   VkPhysicalDeviceMapMemoryPlacedPropertiesEXT mpp = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAP_MEMORY_PLACED_PROPERTIES_EXT };
   VkPhysicalDeviceProperties2 pp = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &mpp };
   vkGetPhysicalDeviceProperties2(pd, &pp);
   printf("device %s, minPlacedMemoryMapAlignment %llu\n", pp.properties.deviceName, (unsigned long long)mpp.minPlacedMemoryMapAlignment);
   VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   gdpa = (PFN_vkGetDeviceProcAddr)gipa(inst, "vkGetDeviceProcAddr");
   VkPhysicalDeviceMapMemoryPlacedFeaturesEXT mf = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAP_MEMORY_PLACED_FEATURES_EXT,
      .memoryMapPlaced = 1, .memoryUnmapReserve = 1 };
   const char *ext[] = { "VK_KHR_map_memory2", "VK_EXT_map_memory_placed" };
   float pr = 1; VkDeviceQueueCreateInfo q = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &pr };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &mf, .queueCreateInfoCount = 1, .pQueueCreateInfos = &q,
      .enabledExtensionCount = 2, .ppEnabledExtensionNames = ext };
   CK(vkCreateDevice(pd, &dci, NULL, &dev));
   D(vkGetDeviceQueue); D(vkCreateBuffer); D(vkGetBufferMemoryRequirements); D(vkAllocateMemory); D(vkBindBufferMemory);
   D(vkMapMemory2KHR); D(vkUnmapMemory2KHR); D(vkMapMemory); D(vkCreateCommandPool); D(vkAllocateCommandBuffers);
   D(vkBeginCommandBuffer); D(vkEndCommandBuffer); D(vkCmdCopyBuffer); D(vkQueueSubmit); D(vkQueueWaitIdle); D(vkFreeMemory);
   D(vkDestroyBuffer);
   VkQueue queue; vkGetDeviceQueue(dev, 0, 0, &queue);
   VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
   VkCommandPool pool; CK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
   const VkDeviceSize SZ = 4u << 20;
   int fails = 0;
   for (uint32_t t = 0; t < mp.memoryTypeCount; t++) {
      const VkMemoryPropertyFlags f = mp.memoryTypes[t].propertyFlags;
      if (!(f & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) continue;
      VkBuffer a, b; VkDeviceMemory ma, mb;
      VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = SZ, .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT };
      CK(vkCreateBuffer(dev, &bci, NULL, &a)); CK(vkCreateBuffer(dev, &bci, NULL, &b));
      VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, a, &mr);
      if (!(mr.memoryTypeBits >> t & 1)) continue;
      VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = SZ, .memoryTypeIndex = t };
      CK(vkAllocateMemory(dev, &mai, NULL, &ma)); CK(vkAllocateMemory(dev, &mai, NULL, &mb));
      CK(vkBindBufferMemory(dev, a, ma, 0)); CK(vkBindBufferMemory(dev, b, mb, 0));
      // reserve a range, as DXVK/Wine does, and place the map there
      void *res = mmap(NULL, SZ, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
      VkMemoryMapPlacedInfoEXT pl = { .sType = VK_STRUCTURE_TYPE_MEMORY_MAP_PLACED_INFO_EXT, .pPlacedAddress = res };
      VkMemoryMapInfoKHR mi = { .sType = VK_STRUCTURE_TYPE_MEMORY_MAP_INFO_KHR, .pNext = &pl, .flags = VK_MEMORY_MAP_PLACED_BIT_EXT,
         .memory = ma, .offset = 0, .size = VK_WHOLE_SIZE };
      void *p = NULL; VkResult r = vkMapMemory2KHR(dev, &mi, &p);
      printf("type %u (flags 0x%x): placed map at %p -> %d, %p%s\n", t, f, res, r, p, p == res ? "" : " (NOT the placed address)");
      if (r || p != res) { fails++; continue; }
      for (uint32_t i = 0; i < SZ / 4; i++) ((uint32_t *)p)[i] = i * 2654435761u ^ t;
      VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
      VkCommandBuffer cb; CK(vkAllocateCommandBuffers(dev, &cai, &cb));
      VkCommandBufferBeginInfo bb = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
      CK(vkBeginCommandBuffer(cb, &bb)); VkBufferCopy bc = { 0, 0, SZ }; vkCmdCopyBuffer(cb, a, b, 1, &bc); CK(vkEndCommandBuffer(cb));
      VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
      CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE)); CK(vkQueueWaitIdle(queue));
      void *pb; CK(vkMapMemory(dev, mb, 0, VK_WHOLE_SIZE, 0, &pb));
      long bad = 0; for (uint32_t i = 0; i < SZ / 4; i++) if (((uint32_t *)pb)[i] != (i * 2654435761u ^ t)) bad++;
      printf("  GPU copy of what the placed map wrote: %ld dwords differ %s\n", bad, bad ? "FAIL" : "PASS");
      fails += bad != 0;
      VkMemoryUnmapInfoKHR ui = { .sType = VK_STRUCTURE_TYPE_MEMORY_UNMAP_INFO_KHR, .flags = VK_MEMORY_UNMAP_RESERVE_BIT_EXT, .memory = ma };
      CK(vkUnmapMemory2KHR(dev, &ui));
      // the range must be reserved again: a fixed anonymous map there must not clobber a live mapping (it is ours)
      void *again = mmap(res, SZ, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
      printf("  after unmap with RESERVE: the range is ours again (%s)\n", again == res ? "PASS" : "FAIL");
      fails += again != res;
      munmap(res, SZ);
      vkFreeMemory(dev, ma, NULL); vkFreeMemory(dev, mb, NULL); vkDestroyBuffer(dev, a, NULL); vkDestroyBuffer(dev, b, NULL);
   }
   printf("%s\n", fails ? "FAILED" : "ALL PASSED");
   return fails != 0;
}
