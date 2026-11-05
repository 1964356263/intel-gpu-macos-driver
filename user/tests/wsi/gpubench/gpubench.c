// SPDX-License-Identifier: MIT
// gpubench: raw Vulkan compute throughput on the B580 (no Metal plugin in between): FP32 FMA rate, compute and
// vkCmdCopyBuffer VRAM bandwidth, timed with GPU timestamps. Through the Khronos loader (/usr/local/lib).
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>
#include "fma_spv.h"
#include "copy_spv.h"
static PFN_vkGetInstanceProcAddr gipa; static PFN_vkGetDeviceProcAddr gdpa; static VkInstance inst; static VkDevice dev;
#define I(n) PFN_##n n = (PFN_##n)gipa(inst, #n)
#define D(n) PFN_##n n = (PFN_##n)gdpa(dev, #n)
#define CK(x) do { VkResult r_ = (x); if (r_) { printf("FAIL %s = %d\n", #x, r_); exit(1); } } while (0)
int main(void) {
   void *lib = dlopen("/usr/local/lib/libvulkan.1.dylib", RTLD_NOW); if (!lib) { printf("no loader\n"); return 1; }
   gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
   I(vkCreateInstance);
   VkApplicationInfo ai = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai };
   CK(vkCreateInstance(&ici, NULL, &inst));
   I(vkEnumeratePhysicalDevices); I(vkGetPhysicalDeviceProperties); I(vkCreateDevice); I(vkGetPhysicalDeviceMemoryProperties);
   uint32_t n = 1; VkPhysicalDevice pd; vkEnumeratePhysicalDevices(inst, &n, &pd);
   VkPhysicalDeviceProperties pp; vkGetPhysicalDeviceProperties(pd, &pp);
   VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
   gdpa = (PFN_vkGetDeviceProcAddr)gipa(inst, "vkGetDeviceProcAddr");
   float pr = 1; VkDeviceQueueCreateInfo q = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1, .pQueuePriorities = &pr };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &q };
   CK(vkCreateDevice(pd, &dci, NULL, &dev));
   D(vkGetDeviceQueue); D(vkCreateBuffer); D(vkGetBufferMemoryRequirements); D(vkAllocateMemory); D(vkBindBufferMemory);
   D(vkCreateShaderModule); D(vkCreateDescriptorSetLayout); D(vkCreatePipelineLayout); D(vkCreateComputePipelines);
   D(vkCreateDescriptorPool); D(vkAllocateDescriptorSets); D(vkUpdateDescriptorSets); D(vkCreateCommandPool);
   D(vkAllocateCommandBuffers); D(vkBeginCommandBuffer); D(vkEndCommandBuffer); D(vkCmdBindPipeline); D(vkCmdBindDescriptorSets);
   D(vkCmdPushConstants); D(vkCmdDispatch); D(vkCmdWriteTimestamp); D(vkCmdResetQueryPool); D(vkCreateQueryPool);
   D(vkGetQueryPoolResults); D(vkQueueSubmit); D(vkQueueWaitIdle); D(vkCmdCopyBuffer); D(vkCmdPipelineBarrier);
   VkQueue queue; vkGetDeviceQueue(dev, 0, 0, &queue);
   printf("device %s\n", pp.deviceName);
   const VkDeviceSize SZ = 512ull << 20;
   VkBuffer buf[2]; VkDeviceMemory mem[2];
   for (int i = 0; i < 2; i++) {
      VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = SZ,
         .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT };
      CK(vkCreateBuffer(dev, &bi, NULL, &buf[i]));
      VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, buf[i], &mr);
      uint32_t t = 0; for (; t < mp.memoryTypeCount; t++) if ((mr.memoryTypeBits >> t & 1) && mp.memoryTypes[t].propertyFlags == VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) break;
      VkMemoryAllocateInfo ma = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = t };
      CK(vkAllocateMemory(dev, &ma, NULL, &mem[i])); CK(vkBindBufferMemory(dev, buf[i], mem[i], 0));
   }
   VkDescriptorSetLayoutBinding b[2] = { { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT }, { 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT } };
   VkDescriptorSetLayoutCreateInfo dl = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 2, .pBindings = b };
   VkDescriptorSetLayout dsl; CK(vkCreateDescriptorSetLayout(dev, &dl, NULL, &dsl));
   VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 8 };
   VkPipelineLayoutCreateInfo pl = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
   VkPipelineLayout lay; CK(vkCreatePipelineLayout(dev, &pl, NULL, &lay));
   VkPipeline pipe[2]; const uint32_t *code[2] = { (const uint32_t *)fma_spv, (const uint32_t *)copy_spv }; size_t clen[2] = { fma_spv_len, copy_spv_len };
   for (int i = 0; i < 2; i++) {
      VkShaderModuleCreateInfo sm = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = clen[i], .pCode = code[i] };
      VkShaderModule m; CK(vkCreateShaderModule(dev, &sm, NULL, &m));
      VkComputePipelineCreateInfo cp = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .layout = lay,
         .stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = m, .pName = "main" } };
      CK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cp, NULL, &pipe[i]));
   }
   VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2 };
   VkDescriptorPoolCreateInfo dpc = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
   VkDescriptorPool dp; CK(vkCreateDescriptorPool(dev, &dpc, NULL, &dp));
   VkDescriptorSetAllocateInfo dsa = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &dsl };
   VkDescriptorSet ds; CK(vkAllocateDescriptorSets(dev, &dsa, &ds));
   VkDescriptorBufferInfo dbi[2] = { { buf[0], 0, VK_WHOLE_SIZE }, { buf[1], 0, VK_WHOLE_SIZE } };
   VkWriteDescriptorSet w[2] = { { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 0, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi[0] },
                                 { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 1, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi[1] } };
   vkUpdateDescriptorSets(dev, 2, w, 0, NULL);
   VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
   VkCommandPool pool; CK(vkCreateCommandPool(dev, &cpi, NULL, &pool));
   VkQueryPoolCreateInfo qpi = { .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = 8 };
   VkQueryPool qp; CK(vkCreateQueryPool(dev, &qpi, NULL, &qp));
   const uint32_t fma_threads = 4u << 20, iters = 256;   // 4M threads x 256 x 8 vec4 FMAs
   for (int rep = 0; rep < 3; rep++) {
      VkCommandBufferAllocateInfo ca = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .commandBufferCount = 1 };
      VkCommandBuffer cb; CK(vkAllocateCommandBuffers(dev, &ca, &cb));
      VkCommandBufferBeginInfo bb = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
      CK(vkBeginCommandBuffer(cb, &bb));
      vkCmdResetQueryPool(cb, qp, 0, 8);
      vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, lay, 0, 1, &ds, 0, NULL);
      VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT };
      vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, qp, 0);
      vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe[0]);
      struct { uint32_t it; float k; } pc = { iters, 0.999f };
      vkCmdPushConstants(cb, lay, VK_SHADER_STAGE_COMPUTE_BIT, 0, 8, &pc);
      vkCmdDispatch(cb, fma_threads / 256, 1, 1);
      vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
      vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, qp, 1);
      vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe[1]);
      vkCmdDispatch(cb, (uint32_t)(SZ / 16 / 256), 1, 1);
      vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
      vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, qp, 2);
      VkBufferCopy bc = { 0, 0, SZ };
      vkCmdCopyBuffer(cb, buf[1], buf[0], 1, &bc);
      vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
      vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, qp, 3);
      CK(vkEndCommandBuffer(cb));
      VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
      CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE)); CK(vkQueueWaitIdle(queue));
      uint64_t ts[4]; CK(vkGetQueryPoolResults(dev, qp, 0, 4, sizeof ts, ts, 8, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
      const double tp = pp.limits.timestampPeriod;
      double t_fma = (ts[1] - ts[0]) * tp * 1e-9, t_cc = (ts[2] - ts[1]) * tp * 1e-9, t_cp = (ts[3] - ts[2]) * tp * 1e-9;
      double flops = (double)fma_threads * iters * 8 * 4 * 2;
      printf("rep %d: FMA %.0f GFLOPS (%.2f ms); compute copy %.0f GB/s (%.2f ms, %u MB read + written); vkCmdCopyBuffer %.0f GB/s (%.2f ms)\n",
             rep, flops / t_fma / 1e9, t_fma * 1e3, 2.0 * SZ / t_cc / 1e9, t_cc * 1e3, (unsigned)(SZ >> 20), 2.0 * SZ / t_cp / 1e9, t_cp * 1e3);
   }
   return 0;
}
