/*
 * nvmtl_dbuf.c - the descriptor-buffer model (DESCRIPTOR-MODEL.md, stage 2), included by nvmtl_vk.c.
 *
 * NVMTL_DESC_MODEL=buffer on a device with VK_EXT_descriptor_buffer (descriptorBuffer): descriptors are bytes the plugin
 * writes into GPU-visible memory itself, and a draw or dispatch points each set at them with
 * vkCmdSetDescriptorBufferOffsetsEXT. No VkDescriptorPool, VkDescriptorSet, vkUpdateDescriptorSets or
 * vkCmdBindDescriptorSets is used in that mode, by any pipeline: ANV on Xe2 emits a CS stall + STATE_BASE_ADDRESS
 * whenever a command buffer switches between classic sets and descriptor buffers (genX_cmd_buffer.c, binding modes), so
 * every layout the plugin creates is a descriptor-buffer layout or has no sets (visibility sum).
 *
 *   - Per pipeline and stage, a compact set layout: only the bindings the stage's SPIR-V reads (the masks the classic
 *     model already computes), with their binding numbers, so the SPIR-V is unchanged. Layouts are shared through a
 *     cache keyed by the binding set (nvmtl_db_plan).
 *   - Per command buffer, a ring of descriptor memory (256 KiB pages, kept and reused exactly like the address-table
 *     pages, witness-guarded). A draw whose stage has new bindings (or a new plan) gets a fresh region for that stage:
 *     the plan's descriptors are copied from a host-side shadow (one 64-byte descriptor per slot, regenerated with
 *     vkGetDescriptorEXT only for slots that changed), never read back from the GPU-visible memory.
 *   - The address table (binding 640) is a plain UNIFORM_BUFFER (or STORAGE_BUFFER) descriptor: descriptor-buffer
 *     layouts have no dynamic descriptors. A new table is written with every new region of the stage.
 *   - The bindless heap (set 2) is one process-wide descriptor buffer written by nvmtl_vk_bindless_put/_sampler_slot.
 *   - Framebuffer fetch (set 3) is a small region per fetch draw.
 *
 * Descriptor contents match the classic model's writes (same views, layouts, ranges, null descriptors and dummies), so
 * images rendered under either model are identical.
 */

enum { NVMTL_DBT_SSBO, NVMTL_DBT_UBO, NVMTL_DBT_TEX, NVMTL_DBT_TEXBUF, NVMTL_DBT_SAMP, NVMTL_DBT_STEX, NVMTL_DBT_STEXBUF,
       NVMTL_DBT_INPUT, NVMTL_DBT_N };
static const VkDescriptorType g_dbt_vk[NVMTL_DBT_N] = {
    VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
    VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, VK_DESCRIPTOR_TYPE_SAMPLER, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
    VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT };
#define NVMTL_DB_MAXDESC 64u
static uint32_t g_dbt_size[NVMTL_DBT_N];
static uint32_t g_db_align = 64;
static PFN_vkGetDescriptorSetLayoutSizeEXT          pvkGetDescriptorSetLayoutSizeEXT;
static PFN_vkGetDescriptorSetLayoutBindingOffsetEXT pvkGetDescriptorSetLayoutBindingOffsetEXT;
static PFN_vkGetDescriptorEXT                       pvkGetDescriptorEXT;
static PFN_vkCmdBindDescriptorBuffersEXT            pvkCmdBindDescriptorBuffersEXT;
static PFN_vkCmdSetDescriptorBufferOffsetsEXT       pvkCmdSetDescriptorBufferOffsetsEXT;
static _Atomic unsigned long long g_db_regions, g_db_reuse, g_db_gen, g_db_pages, g_db_bigpages;
static void nvmtl_db_census(void);

/* ---- device setup --------------------------------------------------------------------------------------------------- */

/* Before vkCreateDevice: is the buffer model wanted (NVMTL_DESC_MODEL=buffer) and possible? Fills the feature struct to
   chain into vkCreateDevice. The extension is enabled only then: with it enabled ANV starts every command buffer in
   descriptor-buffer mode, which classic sets would leave again (an SBA and a stall per command buffer). */
/* Which model this process asked for, read once when the device is made:
     NVMTL_DESC_MODEL=buffer | classic        decides, when set
     /tmp/nvmtl-desc-buffer-<process name>     buffer for that process only (e.g. /tmp/nvmtl-desc-buffer-java)
     /tmp/nvmtl-desc-buffer                    buffer for every process that starts while it exists, except WindowServer
                                               (which needs its own named file)
   The files follow the other diagnostic flags (nvmtl_diag_flag: a regular file owned by root or this user, never a
   symlink). A process keeps its model for its lifetime. */
static int nvmtl_db_wanted(const char **why)
{
    const char *e = getenv("NVMTL_DESC_MODEL");
    if (e && *e) { *why = !strcmp(e, "buffer") ? "NVMTL_DESC_MODEL=buffer" : "NVMTL_DESC_MODEL"; return !strcmp(e, "buffer"); }
    static char name[96];
    snprintf(name, sizeof name, "desc-buffer-%s", getprogname());
    if (nvmtl_diag_flag(name)) { *why = "/tmp/nvmtl-desc-buffer-<process>"; return 1; }
    if (strcmp(getprogname(), "WindowServer") && nvmtl_diag_flag("desc-buffer")) { *why = "/tmp/nvmtl-desc-buffer"; return 1; }
    *why = "default";
    return 0;
}
static int nvmtl_db_probe(VkPhysicalDeviceDescriptorBufferFeaturesEXT *feat)
{
    const char *why = NULL;
    const int want = nvmtl_db_wanted(&why);
    if (!want) { nvlog("vk: descriptor model CLASSIC (descriptor sets; %s)", why); return 0; }
    nvlog("vk: descriptor model BUFFER asked by %s", why);
    uint32_t na = 0; int have = 0;
    if (pvkEnumerateDeviceExtensionProperties && pvkEnumerateDeviceExtensionProperties(g_pdev, NULL, &na, NULL) == VK_SUCCESS && na) {
        VkExtensionProperties *props = calloc(na, sizeof *props);
        if (props && pvkEnumerateDeviceExtensionProperties(g_pdev, NULL, &na, props) == VK_SUCCESS)
            for (uint32_t i = 0; i < na && !have; i++) have = !strcmp(props[i].extensionName, VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME);
        free(props);
    }
    PFN_vkGetPhysicalDeviceFeatures2 gpf = (PFN_vkGetPhysicalDeviceFeatures2)pvkGetInstanceProcAddr(g_inst, "vkGetPhysicalDeviceFeatures2");
    VkPhysicalDeviceDescriptorBufferFeaturesEXT q = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT };
    VkPhysicalDeviceFeatures2 f2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, &q };
    if (have && gpf) gpf(g_pdev, &f2);
    g_dbp = (VkPhysicalDeviceDescriptorBufferPropertiesEXT){ VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_PROPERTIES_EXT };
    VkPhysicalDeviceProperties2 p2 = { VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &g_dbp };
    if (have && q.descriptorBuffer && pvkGetPhysicalDeviceProperties2) pvkGetPhysicalDeviceProperties2(g_pdev, &p2);
    const int ok = have && q.descriptorBuffer && g_dbp.descriptorBufferOffsetAlignment && g_dbp.maxResourceDescriptorBufferBindings >= 2 &&
                   g_dbp.maxSamplerDescriptorBufferBindings >= 2 && g_dbp.maxDescriptorBufferBindings >= 2;
    if (!ok) { nvlog("vk: descriptor model CLASSIC - NVMTL_DESC_MODEL=buffer asked, but VK_EXT_descriptor_buffer is %s",
                     !have ? "absent" : !q.descriptorBuffer ? "without descriptorBuffer" : "too limited (bindings/alignment)"); return 0; }
    *feat = (VkPhysicalDeviceDescriptorBufferFeaturesEXT){ VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT, NULL, VK_TRUE };
    return 1;
}
/* After vkCreateDevice: the entry points and descriptor sizes. 0 = the model stays on; -1 = it cannot (logged). */
static int nvmtl_db_device_ready(int robust)
{
    pvkGetDescriptorSetLayoutSizeEXT = (PFN_vkGetDescriptorSetLayoutSizeEXT)pvkGetDeviceProcAddr(g_dev, "vkGetDescriptorSetLayoutSizeEXT");
    pvkGetDescriptorSetLayoutBindingOffsetEXT = (PFN_vkGetDescriptorSetLayoutBindingOffsetEXT)pvkGetDeviceProcAddr(g_dev, "vkGetDescriptorSetLayoutBindingOffsetEXT");
    pvkGetDescriptorEXT = (PFN_vkGetDescriptorEXT)pvkGetDeviceProcAddr(g_dev, "vkGetDescriptorEXT");
    pvkCmdBindDescriptorBuffersEXT = (PFN_vkCmdBindDescriptorBuffersEXT)pvkGetDeviceProcAddr(g_dev, "vkCmdBindDescriptorBuffersEXT");
    pvkCmdSetDescriptorBufferOffsetsEXT = (PFN_vkCmdSetDescriptorBufferOffsetsEXT)pvkGetDeviceProcAddr(g_dev, "vkCmdSetDescriptorBufferOffsetsEXT");
    if (!pvkGetDescriptorSetLayoutSizeEXT || !pvkGetDescriptorSetLayoutBindingOffsetEXT || !pvkGetDescriptorEXT ||
        !pvkCmdBindDescriptorBuffersEXT || !pvkCmdSetDescriptorBufferOffsetsEXT) {
        nvlog("vk: descriptor model: VK_EXT_descriptor_buffer entry points MISSING - classic sets (with the extension enabled)");
        return -1;
    }
    /* robustBufferAccess on: buffer descriptors take the robust sizes */
    g_dbt_size[NVMTL_DBT_SSBO]    = (uint32_t)(robust ? g_dbp.robustStorageBufferDescriptorSize : g_dbp.storageBufferDescriptorSize);
    g_dbt_size[NVMTL_DBT_UBO]     = (uint32_t)(robust ? g_dbp.robustUniformBufferDescriptorSize : g_dbp.uniformBufferDescriptorSize);
    g_dbt_size[NVMTL_DBT_TEX]     = (uint32_t)g_dbp.sampledImageDescriptorSize;
    g_dbt_size[NVMTL_DBT_TEXBUF]  = (uint32_t)(robust ? g_dbp.robustUniformTexelBufferDescriptorSize : g_dbp.uniformTexelBufferDescriptorSize);
    g_dbt_size[NVMTL_DBT_SAMP]    = (uint32_t)g_dbp.samplerDescriptorSize;
    g_dbt_size[NVMTL_DBT_STEX]    = (uint32_t)g_dbp.storageImageDescriptorSize;
    g_dbt_size[NVMTL_DBT_STEXBUF] = (uint32_t)(robust ? g_dbp.robustStorageTexelBufferDescriptorSize : g_dbp.storageTexelBufferDescriptorSize);
    g_dbt_size[NVMTL_DBT_INPUT]   = (uint32_t)g_dbp.inputAttachmentDescriptorSize;
    for (int k = 0; k < NVMTL_DBT_N; k++)
        if (!g_dbt_size[k] || g_dbt_size[k] > NVMTL_DB_MAXDESC) {
            nvlog("vk: descriptor model: descriptor type %d is %u bytes (shadow holds %u) - classic sets", k, g_dbt_size[k], NVMTL_DB_MAXDESC);
            return -1;
        }
    g_db_align = (uint32_t)g_dbp.descriptorBufferOffsetAlignment;
    nvlog("vk: descriptor model BUFFER (VK_EXT_descriptor_buffer): sizes ssbo %u ubo %u image %u texel %u "
          "sampler %u storage %u/%u input %u, offset alignment %u, %u buffer bindings",
          g_dbt_size[0], g_dbt_size[1], g_dbt_size[2], g_dbt_size[3], g_dbt_size[4], g_dbt_size[5], g_dbt_size[6], g_dbt_size[7],
          g_db_align, g_dbp.maxDescriptorBufferBindings);
    return 0;
}
/* VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT for every pipeline in buffer mode (also those with no sets) */
static VkPipelineCreateFlags nvmtl_db_pipeline_flags(void) { return g_dbuf ? VK_PIPELINE_CREATE_DESCRIPTOR_BUFFER_BIT_EXT : 0; }
static VkDescriptorSetLayoutCreateFlags nvmtl_db_layout_flags(void) { return g_dbuf ? VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT : 0; }

/* ---- descriptor memory ---------------------------------------------------------------------------------------------- */

typedef struct { VkBuffer buf; VkDeviceMemory mem; uint8_t *map; uint64_t addr; size_t size; } nvmtl_dbmem;
/* A buffer descriptors can be read from: ANV puts it in its dynamic-visible address range (the memory types its
   descriptor-buffer usage allows). Host-visible, coherent and mapped for the process; device-local when the BAR offers it. */
static int nvmtl_db_mem_create(size_t size, nvmtl_dbmem *m)
{
    memset(m, 0, sizeof *m);
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, size,
        VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT |
        VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT, VK_SHARING_MODE_EXCLUSIVE, 0, NULL };
    if (pvkCreateBuffer(g_dev, &bci, NULL, &m->buf) != VK_SUCCESS) { m->buf = VK_NULL_HANDLE; return -1; }
    VkMemoryRequirements mr; pvkGetBufferMemoryRequirements(g_dev, m->buf, &mr);
    const VkMemoryPropertyFlags hv = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    int mt = -1;
    for (uint32_t i = 0; i < g_memp.memoryTypeCount && mt < 0; i++)
        if ((mr.memoryTypeBits & (1u << i)) && (g_memp.memoryTypes[i].propertyFlags & (hv | VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) == (hv | VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) mt = (int)i;
    for (uint32_t i = 0; i < g_memp.memoryTypeCount && mt < 0; i++)
        if ((mr.memoryTypeBits & (1u << i)) && (g_memp.memoryTypes[i].propertyFlags & hv) == hv) mt = (int)i;
    if (mt < 0) { pvkDestroyBuffer(g_dev, m->buf, NULL); m->buf = VK_NULL_HANDLE; nvlog("vk: descriptor buffer: no host-visible memory type (bits 0x%x)", mr.memoryTypeBits); return -1; }
    VkMemoryAllocateFlagsInfo fi = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO, NULL, VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT, 0 };
    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, &fi, mr.size, (uint32_t)mt };
    void *map = NULL;
    if (pvkAllocateMemory(g_dev, &mai, NULL, &m->mem) != VK_SUCCESS) { m->mem = VK_NULL_HANDLE; goto fail; }
    if (pvkBindBufferMemory(g_dev, m->buf, m->mem, 0) != VK_SUCCESS) goto fail;
    if (pvkMapMemory(g_dev, m->mem, 0, VK_WHOLE_SIZE, 0, &map) != VK_SUCCESS || !map) goto fail;
    VkBufferDeviceAddressInfo ai = { VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO, NULL, m->buf };
    m->addr = pvkGetBufferDeviceAddress(g_dev, &ai);
    if (!m->addr) goto fail;
    m->map = (uint8_t *)map; m->size = size;
    return 0;
fail:
    nvlog("vk: descriptor buffer of %zu bytes NOT made (memory type %d)", size, mt);
    if (m->mem) pvkFreeMemory(g_dev, m->mem, NULL);
    pvkDestroyBuffer(g_dev, m->buf, NULL);
    memset(m, 0, sizeof *m);
    return -1;
}
static void nvmtl_db_mem_destroy(nvmtl_dbmem *m)
{
    if (m->mem) pvkFreeMemory(g_dev, m->mem, NULL);   // unmapped by the free
    if (m->buf) pvkDestroyBuffer(g_dev, m->buf, NULL);
    memset(m, 0, sizeof *m);
}

/* ---- descriptor bytes ----------------------------------------------------------------------------------------------- */

/* Texel buffer views: a descriptor is made from the address, range and format, not from the VkBufferView, so each view
   nvmtl_vk_texel_view_create makes is recorded here until nvmtl_vk_texel_view_destroy. */
#define NVMTL_TV_CAP (1u << 16)
typedef struct { const void *view; uint64_t addr, range; uint32_t fmt; } nvmtl_tvinfo;
static nvmtl_tvinfo *g_tv; static uint32_t g_tv_n; static pthread_mutex_t g_tv_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t nvmtl_tv_hash(const void *p) { uint64_t x = (uint64_t)(uintptr_t)p; x ^= x >> 33; x *= 0xff51afd7ed558ccdull; x ^= x >> 33; return (uint32_t)x & (NVMTL_TV_CAP - 1); }
static void nvmtl_db_texel_note(const void *view, uint64_t addr, uint64_t range, uint32_t fmt)
{
    if (!g_dbuf || !view) return;
    pthread_mutex_lock(&g_tv_lock);
    if (!g_tv) g_tv = (nvmtl_tvinfo *)calloc(NVMTL_TV_CAP, sizeof *g_tv);
    if (g_tv && g_tv_n < NVMTL_TV_CAP / 2) {
        uint32_t h = nvmtl_tv_hash(view);
        while (g_tv[h].view && g_tv[h].view != view) h = (h + 1) & (NVMTL_TV_CAP - 1);
        if (!g_tv[h].view) g_tv_n++;
        g_tv[h] = (nvmtl_tvinfo){ view, addr, range, fmt };
    } else { static int said; if (!said++) nvlog("vk: descriptor buffer: texel view table FULL - a texel buffer reads as null"); }
    pthread_mutex_unlock(&g_tv_lock);
}
static void nvmtl_db_texel_forget(const void *view)
{
    if (!view) return;
    pthread_mutex_lock(&g_tv_lock);
    if (!g_tv) { pthread_mutex_unlock(&g_tv_lock); return; }
    uint32_t i = nvmtl_tv_hash(view);
    while (g_tv[i].view && g_tv[i].view != view) i = (i + 1) & (NVMTL_TV_CAP - 1);
    if (g_tv[i].view) {
        g_tv[i].view = NULL; g_tv_n--;
        for (uint32_t j = i;;) {   // backward-shift deletion (open addressing, linear probing)
            j = (j + 1) & (NVMTL_TV_CAP - 1);
            if (!g_tv[j].view) break;
            uint32_t k = nvmtl_tv_hash(g_tv[j].view);
            if ((j > i && (k <= i || k > j)) || (j < i && (k <= i && k > j))) { g_tv[i] = g_tv[j]; g_tv[j].view = NULL; i = j; }
        }
    }
    pthread_mutex_unlock(&g_tv_lock);
}
static int nvmtl_db_texel_find(const void *view, VkDescriptorAddressInfoEXT *out)
{
    int found = 0;
    pthread_mutex_lock(&g_tv_lock);
    if (g_tv && view) {
        uint32_t h = nvmtl_tv_hash(view);
        while (g_tv[h].view && g_tv[h].view != view) h = (h + 1) & (NVMTL_TV_CAP - 1);
        if (g_tv[h].view) { *out = (VkDescriptorAddressInfoEXT){ VK_STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT, NULL, g_tv[h].addr, g_tv[h].range, (VkFormat)g_tv[h].fmt }; found = 1; }
    }
    pthread_mutex_unlock(&g_tv_lock);
    return found;
}

static void nvmtl_db_get_image(int type, const void *view, VkImageLayout layout, uint8_t *out)
{
    VkDescriptorImageInfo ii = { VK_NULL_HANDLE, (VkImageView)view, layout };
    VkDescriptorGetInfoEXT gi = { VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT, NULL, g_dbt_vk[type], { 0 } };
    if (type == NVMTL_DBT_STEX) gi.data.pStorageImage = view ? &ii : NULL;
    else if (type == NVMTL_DBT_INPUT) gi.data.pInputAttachmentImage = view ? &ii : NULL;
    else gi.data.pSampledImage = view ? &ii : NULL;
    pvkGetDescriptorEXT(g_dev, &gi, g_dbt_size[type], out);
}
static void nvmtl_db_get_sampler(const void *s, uint8_t *out)
{
    VkSampler h = (VkSampler)s;
    VkDescriptorGetInfoEXT gi = { VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT, NULL, VK_DESCRIPTOR_TYPE_SAMPLER, { 0 } };
    gi.data.pSampler = &h;
    pvkGetDescriptorEXT(g_dev, &gi, g_dbt_size[NVMTL_DBT_SAMP], out);
}
static void nvmtl_db_get_buffer(int type, uint64_t addr, uint64_t range, uint8_t *out)
{
    VkDescriptorAddressInfoEXT ai = { VK_STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT, NULL, addr, range, VK_FORMAT_UNDEFINED };
    VkDescriptorGetInfoEXT gi = { VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT, NULL, g_dbt_vk[type], { 0 } };
    if (type == NVMTL_DBT_UBO) gi.data.pUniformBuffer = addr ? &ai : NULL; else gi.data.pStorageBuffer = addr ? &ai : NULL;
    pvkGetDescriptorEXT(g_dev, &gi, g_dbt_size[type], out);
}
static void nvmtl_db_get_texel(int type, const void *view, uint8_t *out)
{
    VkDescriptorAddressInfoEXT ai; const int have = view && nvmtl_db_texel_find(view, &ai);
    VkDescriptorGetInfoEXT gi = { VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT, NULL, g_dbt_vk[type], { 0 } };
    if (type == NVMTL_DBT_STEXBUF) gi.data.pStorageTexelBuffer = have ? &ai : NULL; else gi.data.pUniformTexelBuffer = have ? &ai : NULL;
    pvkGetDescriptorEXT(g_dev, &gi, g_dbt_size[type], out);
}
static uint64_t nvmtl_db_dummy_addr(void)
{
    static uint64_t a;
    uint64_t v = __atomic_load_n(&a, __ATOMIC_RELAXED);
    if (!v) { v = nvmtl_vk_buffer_address(&g_dummyBuf); __atomic_store_n(&a, v, __ATOMIC_RELAXED); }
    return v;
}
/* Slot i of stage `which` as a descriptor of `type`: what nvmtl_snapshot_set_md writes for it in the classic model. */
static void nvmtl_db_gen(const nvmtl_slot *sl, uint32_t which, uint32_t i, int type, uint8_t *out)
{
    sl = nvmtl_slot_checked(sl, which, i);
    switch (type) {
    case NVMTL_DBT_SSBO:
        if (sl && sl->kind == NVMTL_SLOT_BUF) {
            const size_t at = sl->off & ~(size_t)(NVMTL_SSBO_ALIGN - 1);   // the shader adds the remainder (classic model)
            const size_t whole = sl->size + sl->vextra;                      // VK_WHOLE_SIZE of the VkBuffer
            nvmtl_db_get_buffer(type, sl->address + at, whole > at ? whole - at : 0, out);
        } else if (g_null_desc) nvmtl_db_get_buffer(type, 0, 0, out);
        else nvmtl_db_get_buffer(type, nvmtl_db_dummy_addr(), g_dummyBuf.vksize ? g_dummyBuf.vksize : g_dummyBuf.size, out);
        return;
    case NVMTL_DBT_TEX:
        nvmtl_db_get_image(type, (sl && sl->kind == NVMTL_SLOT_TEX && sl->h) ? sl->h : g_null_desc ? NULL : g_dummyImg.view,
                           VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, out);
        return;
    case NVMTL_DBT_TEXBUF: case NVMTL_DBT_STEXBUF:
        nvmtl_db_get_texel(type, (sl && sl->kind == NVMTL_SLOT_TEXBUF && sl->h) ? sl->h : g_null_desc ? NULL : g_dummyTexView, out);
        return;
    case NVMTL_DBT_SAMP:
        nvmtl_db_get_sampler((sl && sl->kind == NVMTL_SLOT_SAMP && sl->h) ? sl->h : (const void *)g_dummySampler, out);
        return;
    case NVMTL_DBT_STEX: {
        const int bound = sl && sl->kind == NVMTL_SLOT_TEX && sl->h;
        const void *view = bound ? sl->h : g_null_desc ? NULL : g_dummyStex.view;
        if (!view && !g_null_desc) { memset(out, 0, g_dbt_size[type]); return; }   // classic: left unwritten
        nvmtl_db_get_image(type, view, VK_IMAGE_LAYOUT_GENERAL, out);
        return; }
    default:
        memset(out, 0, g_dbt_size[type]);
    }
}

/* ---- per-pipeline layouts (plans) ----------------------------------------------------------------------------------- */

typedef struct { uint16_t slot; uint8_t type; uint8_t pad; uint32_t off; } nvmtl_dbent;
typedef struct nvmtl_dbplan {
    struct nvmtl_dbplan *next;
    uint64_t key[9];                       /* binding mask (4), texel mask (4), storage-texture count */
    VkDescriptorSetLayout layout;
    uint32_t size, n, table;               /* table: the address table's entry index + 1 (0 = none) */
    nvmtl_dbent e[];
} nvmtl_dbplan;
static nvmtl_dbplan *g_dbplans; static unsigned g_dbplan_n;   /* g_desc_lock */
/* The stage layout for: the bindings in mask (NULL = all) below NVMTL_STEX_BASE, storage textures 0..stex_hi-1, and the
   texel-buffer bits tb (NULL = none). empty: no bindings (compute's unused set 1). NULL on failure (logged). */
static const nvmtl_dbplan *nvmtl_db_plan(const uint64_t *mask, uint32_t stex_hi, const uint64_t *tb, int empty)
{
    if (stex_hi > NVMTL_NSTEX) stex_hi = NVMTL_NSTEX;
    if (!g_mutable) tb = NULL;
    uint64_t key[9] = { 0 };
    if (!empty) {
        for (int k = 0; k < 4; k++) key[k] = mask ? mask[k] : ~0ull;
        for (uint32_t i = NVMTL_STEX_BASE; i < 256; i++) key[i >> 6] &= ~(1ull << (i & 63));   // storage textures: stex_hi
        for (int k = 0; k < 4; k++) key[4 + k] = tb ? tb[k] : 0;
        key[8] = stex_hi;
    }
    pthread_mutex_lock(&g_desc_lock);
    for (nvmtl_dbplan *p = g_dbplans; p; p = p->next)
        if (!memcmp(p->key, key, sizeof key)) { pthread_mutex_unlock(&g_desc_lock); return p; }
    VkDescriptorSetLayoutBinding b[NVMTL_NBIND]; uint8_t ty[NVMTL_NBIND]; uint16_t sl[NVMTL_NBIND]; uint32_t n = 0;
    for (uint32_t i = 0; !empty && i < NVMTL_STEX_BASE; i++) {
        if (!((key[i >> 6] >> (i & 63)) & 1)) continue;
        int t;
        if (i == NVMTL_ADDRESS_BINDING) t = nvmtl_table_ubo() ? NVMTL_DBT_UBO : NVMTL_DBT_SSBO;
        else if (i < NVMTL_NBUF) t = NVMTL_DBT_SSBO;
        else if (i < NVMTL_NBUF + NVMTL_NTEX) { const uint32_t k = i - NVMTL_NBUF; t = ((key[4 + (k >> 6)] >> (k & 63)) & 1) ? NVMTL_DBT_TEXBUF : NVMTL_DBT_TEX; }
        else t = NVMTL_DBT_SAMP;
        b[n] = (VkDescriptorSetLayoutBinding){ NVMTL_BINDING_NUMBER(i), g_dbt_vk[t], 1, VK_SHADER_STAGE_ALL, NULL };
        ty[n] = (uint8_t)t; sl[n] = (uint16_t)i; n++;
    }
    for (uint32_t j = 0; !empty && j < stex_hi; j++) {
        const uint32_t i = NVMTL_STEX_BASE + j;
        const int t = ((key[6 + (j >> 6)] >> (j & 63)) & 1) ? NVMTL_DBT_STEXBUF : NVMTL_DBT_STEX;
        b[n] = (VkDescriptorSetLayoutBinding){ NVMTL_BINDING_NUMBER(i), g_dbt_vk[t], 1, VK_SHADER_STAGE_ALL, NULL };
        ty[n] = (uint8_t)t; sl[n] = (uint16_t)i; n++;
    }
    VkDescriptorSetLayoutCreateInfo lci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL,
                                            VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT, n, n ? b : NULL };
    nvmtl_dbplan *p = (nvmtl_dbplan *)calloc(1, sizeof *p + n * sizeof p->e[0]);
    if (!p || pvkCreateDescriptorSetLayout(g_dev, &lci, NULL, &p->layout) != VK_SUCCESS) {
        pthread_mutex_unlock(&g_desc_lock); free(p);
        nvlog("vk: descriptor buffer: stage layout of %u bindings NOT made", n); return NULL;
    }
    memcpy(p->key, key, sizeof key); p->n = n;
    VkDeviceSize size = 0; pvkGetDescriptorSetLayoutSizeEXT(g_dev, p->layout, &size);
    p->size = (uint32_t)size;
    for (uint32_t k = 0; k < n; k++) {
        VkDeviceSize off = 0; pvkGetDescriptorSetLayoutBindingOffsetEXT(g_dev, p->layout, b[k].binding, &off);
        p->e[k] = (nvmtl_dbent){ sl[k], ty[k], 0, (uint32_t)off };
        if (sl[k] == NVMTL_ADDRESS_BINDING) p->table = k + 1;
    }
    p->next = g_dbplans; g_dbplans = p; g_dbplan_n++;
    const unsigned np = g_dbplan_n;
    pthread_mutex_unlock(&g_desc_lock);
    if (np <= 4 || !(np & (np - 1))) nvlog("vk: descriptor buffer: %u stage layouts (this one %u bindings, %u bytes)", np, n, p->size);
    return p;
}
/* The fetch layout's binding offsets (set 3, input attachments 192..199) */
static uint32_t g_db_fetch_off[NVMTL_NCOL], g_db_fetch_size; static int g_db_fetch_ready;
static void nvmtl_db_fetch_offsets_locked(void)
{
    if (g_db_fetch_ready || !g_fetchLayout) return;
    VkDeviceSize s = 0; pvkGetDescriptorSetLayoutSizeEXT(g_dev, g_fetchLayout, &s); g_db_fetch_size = (uint32_t)s;
    for (uint32_t i = 0; i < NVMTL_NCOL; i++) { VkDeviceSize o = 0; pvkGetDescriptorSetLayoutBindingOffsetEXT(g_dev, g_fetchLayout, NVMTL_FETCH_BINDING + i, &o); g_db_fetch_off[i] = (uint32_t)o; }
    g_db_fetch_ready = 1;
}

/* ---- the bindless heap as a descriptor buffer ----------------------------------------------------------------------- */

static nvmtl_dbmem g_dbheap; static uint32_t g_dbheap_img_off, g_dbheap_samp_off;
/* ensure_descriptors_locked, buffer model: binding 0 holds NVMTL_BINDLESS_SLOTS sampled images, binding 1 (unless
   NVMTL_NO_ARGBUF_SAMPLERS=1) NVMTL_BINDLESS_SAMPLER_SLOTS samplers; every slot the dummy (or null) until a texture or
   sampler is placed, as in the classic heap. No update-after-bind: writing descriptor memory is the plugin's own, and the
   slot quarantine (nvmtl_vk_bindless_put) keeps a slot in flight from being rewritten, as before. */
static int nvmtl_db_heap_create_locked(void)
{
    const char *nas = getenv("NVMTL_NO_ARGBUF_SAMPLERS"); const uint32_t hnb = (nas && nas[0] == '1') ? 1u : 2u;
    VkDescriptorSetLayoutBinding hb[2] = { { 0, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, NVMTL_BINDLESS_SLOTS, VK_SHADER_STAGE_ALL, NULL },
                                           { 1, VK_DESCRIPTOR_TYPE_SAMPLER, NVMTL_BINDLESS_SAMPLER_SLOTS, VK_SHADER_STAGE_ALL, NULL } };
    VkDescriptorSetLayoutCreateInfo hli = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL,
                                            VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT, hnb, hb };
    VkDescriptorSetLayout hl = VK_NULL_HANDLE;
    if (pvkCreateDescriptorSetLayout(g_dev, &hli, NULL, &hl) != VK_SUCCESS) { nvlog("vk: BINDLESS heap layout (descriptor buffer) refused - no heap"); return -1; }
    VkDeviceSize size = 0, o0 = 0, o1 = 0;
    pvkGetDescriptorSetLayoutSizeEXT(g_dev, hl, &size);
    pvkGetDescriptorSetLayoutBindingOffsetEXT(g_dev, hl, 0, &o0);
    if (hnb == 2) pvkGetDescriptorSetLayoutBindingOffsetEXT(g_dev, hl, 1, &o1);
    if (nvmtl_db_mem_create((size_t)size, &g_dbheap)) { pvkDestroyDescriptorSetLayout(g_dev, hl, NULL); return -1; }
    g_dbheap_img_off = (uint32_t)o0; g_dbheap_samp_off = (uint32_t)o1;
    uint8_t d[NVMTL_DB_MAXDESC];
    nvmtl_db_get_image(NVMTL_DBT_TEX, g_null_desc ? NULL : g_dummyImg.view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, d);
    const uint32_t is = g_dbt_size[NVMTL_DBT_TEX], ss = g_dbt_size[NVMTL_DBT_SAMP];
    for (uint32_t k = 0; k < NVMTL_BINDLESS_SLOTS; k++) memcpy(g_dbheap.map + g_dbheap_img_off + (size_t)k * is, d, is);
    if (hnb == 2) {
        nvmtl_db_get_sampler((const void *)g_dummySampler, d);
        for (uint32_t k = 0; k < NVMTL_BINDLESS_SAMPLER_SLOTS; k++) memcpy(g_dbheap.map + g_dbheap_samp_off + (size_t)k * ss, d, ss);
        g_heap_sampler_binding = 1;
    }
    g_heapLayout = hl; g_heap_ready = 1; g_heap_nbind = hnb;
    nvlog("vk: BINDLESS heap ready (descriptor buffer, %llu bytes) - set 2, %d sampled images%s", (unsigned long long)size,
          NVMTL_BINDLESS_SLOTS, hnb == 2 ? " + samplers" : "");
    return 0;
}
static void nvmtl_db_heap_write_image(uint32_t slot, const void *view)
{
    const uint32_t is = g_dbt_size[NVMTL_DBT_TEX];
    nvmtl_db_get_image(NVMTL_DBT_TEX, view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, g_dbheap.map + g_dbheap_img_off + (size_t)slot * is);
}
static void nvmtl_db_heap_write_sampler(uint32_t slot, const void *s)
{
    nvmtl_db_get_sampler(s, g_dbheap.map + g_dbheap_samp_off + (size_t)slot * g_dbt_size[NVMTL_DBT_SAMP]);
}

/* ---- the per-command-buffer ring ------------------------------------------------------------------------------------ */

#define NVMTL_DB_PAGE (256u << 10)
#define NVMTL_DB_MRU 4
typedef struct nvmtl_dbpage { nvmtl_dbmem m; struct nvmtl_dbpage *next; } nvmtl_dbpage;
static nvmtl_dbpage *g_dbkeep[NVMTL_KEEP]; static unsigned g_dbkeep_n;   /* g_keep_lock */
static nvmtl_dbpage *nvmtl_db_page_pop(void)
{
    nvmtl_dbpage *p = NULL;
    if (!nvmtl_keep_on()) return NULL;
    pthread_mutex_lock(&g_keep_lock); if (g_dbkeep_n) p = g_dbkeep[--g_dbkeep_n]; pthread_mutex_unlock(&g_keep_lock);
    return p;
}
static int nvmtl_db_page_push(nvmtl_dbpage *p)
{
    int kept = 0;
    if (!nvmtl_keep_on() || p->m.size != NVMTL_DB_PAGE) return 0;
    pthread_mutex_lock(&g_keep_lock); if (g_dbkeep_n < NVMTL_KEEP) { p->next = NULL; g_dbkeep[g_dbkeep_n++] = p; kept = 1; } pthread_mutex_unlock(&g_keep_lock);
    return kept;
}

typedef struct {
    nvmtl_dbpage *pages;               /* pages[0]: the one being filled; the rest are retired with the command buffer */
    uint32_t used, gen;                /* bytes used in pages[0]; gen: bumped per page (offsets name the bound page) */
    uint32_t bound_gen;                /* gen of the page vkCmdBindDescriptorBuffersEXT bound (0 = none yet) */
    const nvmtl_dbplan *plan[2]; uint32_t off[2], ogen[2], oepoch[2], oneed[2];   /* the last region per stage (oneed: its table's entries, stage 1d) */
    VkPipelineLayout lay[2]; uint32_t lgen[2], nset[2], soff[2][4], sidx[2][4];   /* last offsets set, per bind point */
    uint32_t fz_off, fz_gen;           /* the fetch-off region (every input attachment the dummy) */
    uint32_t n_reg, n_reuse, n_gen;    /* census (NVMTL_DBUF_CENSUS=1), added to the process totals at retire */
    /* the stage's recent regions, reusable while none of its bindings changed (epoch) and the page is the same: a
       pipeline switch back and forth (A, B, A ...) finds its region again instead of writing a new one */
    struct { const nvmtl_dbplan *plan; uint32_t off, gen, epoch, need; } mru[2][NVMTL_DB_MRU];
    uint32_t epoch[2], mru_next[2];
    uint64_t valid[2][NVMTL_CHG_WORDS];
    uint8_t ty[2][NVMTL_NBIND];
    uint8_t d[2][NVMTL_NBIND][NVMTL_DB_MAXDESC];   /* each slot's descriptor, made when the slot changes */
} nvmtl_dbstate;

static nvmtl_dbstate *nvmtl_db_state(nvk_cmdbuf *c)
{
    if (c->db) return (nvmtl_dbstate *)c->db;
    nvmtl_dbstate *s = (nvmtl_dbstate *)malloc(sizeof *s);
    if (!s) return NULL;
    // only the bookkeeping is cleared: d[] is written before it is read (valid bits)
    memset(s, 0, offsetof(nvmtl_dbstate, d));
    c->db = s;
    return s;
}
static void nvmtl_db_retire(nvk_cmdbuf *c, int keep)
{
    nvmtl_dbstate *s = (nvmtl_dbstate *)c->db;
    if (!s) return;
    atomic_fetch_add(&g_db_regions, s->n_reg); atomic_fetch_add(&g_db_reuse, s->n_reuse); atomic_fetch_add(&g_db_gen, s->n_gen);
    nvmtl_db_census();
    for (nvmtl_dbpage *p = s->pages; p; ) {
        nvmtl_dbpage *next = p->next;
        // keep < 0: the witness never landed - the page is leaked, never reused (as the address pages)
        if (keep >= 0 && !(keep > 0 && nvmtl_db_page_push(p))) { nvmtl_db_mem_destroy(&p->m); free(p); }
        p = next;
    }
    free(s); c->db = NULL;
}
/* Makes sure `need` more bytes fit in the current page (a new page otherwise). Every region one draw or dispatch uses
   must be in the page bound at index 0, so a bind reserves its worst case first and then allocates without a page change. */
static int nvmtl_db_reserve(nvmtl_dbstate *s, uint32_t need)
{
    const uint32_t a = g_db_align ? g_db_align : 64;
    const uint32_t at = (s->used + a - 1) / a * a;
    if (s->pages && (size_t)at + need <= s->pages->m.size) return 0;
    const size_t want = need <= NVMTL_DB_PAGE ? NVMTL_DB_PAGE : ((size_t)need + 4095) & ~(size_t)4095;
    nvmtl_dbpage *pg = want == NVMTL_DB_PAGE ? nvmtl_db_page_pop() : NULL;
    if (!pg) {
        pg = (nvmtl_dbpage *)calloc(1, sizeof *pg);
        if (!pg || nvmtl_db_mem_create(want, &pg->m)) { free(pg); return -1; }
        atomic_fetch_add(want == NVMTL_DB_PAGE ? &g_db_pages : &g_db_bigpages, 1);
    }
    pg->next = s->pages; s->pages = pg; s->used = 0; s->gen++;
    return 0;
}
/* size bytes of the current page, inside what nvmtl_db_reserve made room for */
static uint8_t *nvmtl_db_alloc(nvmtl_dbstate *s, uint32_t size, uint32_t *off)
{
    const uint32_t a = g_db_align ? g_db_align : 64;
    const uint32_t at = (s->used + a - 1) / a * a;
    if (!s->pages || (size_t)at + size > s->pages->m.size) return NULL;
    s->used = at + size; *off = at;
    return s->pages->m.map + at;
}
/* binds the current page (index 0) and the heap (index 1) when the page changed */
static void nvmtl_db_bind_buffers(nvk_cmdbuf *c, nvmtl_dbstate *s)
{
    if (s->bound_gen == s->gen) return;
    const VkBufferUsageFlags u = VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT;
    VkDescriptorBufferBindingInfoEXT bi[2] = {
        { VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT, NULL, s->pages->m.addr, u },
        { VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT, NULL, g_dbheap.addr, u } };
    pvkCmdBindDescriptorBuffersEXT((VkCommandBuffer)c->cb, g_dbheap.buf ? 2 : 1, bi);
    s->bound_gen = s->gen;
    s->lay[0] = s->lay[1] = VK_NULL_HANDLE;   // offsets are set again for the new page
}

/* The descriptor of the table nvmtl_address_snapshot just placed (slot `ai` of the newest page): made once per page and
   table, then copied (the classic model's dynamic offset did the same job). */
static const uint8_t *nvmtl_db_table_desc(nvk_cmdbuf *c, int type, const VkDescriptorBufferInfo *ai)
{
    nvmtl_address_page *page = (nvmtl_address_page *)c->address_pages;
    const uint32_t k = (uint32_t)(ai->offset / NVMTL_TABLE_BYTES);
    if (!page->udesc && !(page->udesc = (uint8_t *)malloc((size_t)NVMTL_TABLES_PER_PAGE * NVMTL_DB_MAXDESC))) return NULL;
    uint8_t *d = page->udesc + (size_t)k * NVMTL_DB_MAXDESC;
    if (!((page->uvalid[k >> 6] >> (k & 63)) & 1)) {
        nvmtl_db_get_buffer(type, page->addr + ai->offset, ai->range, d);
        page->uvalid[k >> 6] |= 1ull << (k & 63);
    }
    return d;
}
/* The region for stage `which` under plan pl, in the current page: an earlier one when none of the stage's bindings
   changed since (and the page is the same), else a new one. -1 on failure. */
static int nvmtl_db_stage(nvk_cmdbuf *c, nvmtl_dbstate *s, uint32_t which, const nvmtl_dbplan *pl, uint32_t need)
{
    nvmtl_bindtable *t = (nvmtl_bindtable *)c->table;
    if (t && t->dirty[which]) {   // a slot that changed has its descriptor made again when a plan next reads it
        for (int k = 0; k < NVMTL_CHG_WORDS; k++) { s->valid[which][k] &= ~t->chg[which][k]; t->chg[which][k] = 0; }
        t->dirty[which] = 0; s->epoch[which]++;
    }
    // a region is reused only when its table holds the entries this stage reads (stage 1d: tables hold only those)
    if (s->plan[which] == pl && s->ogen[which] == s->gen && s->oepoch[which] == s->epoch[which] && nvmtl_tabneed_covers(s->oneed[which], need)) { s->n_reuse++; return 0; }
    for (uint32_t m = 0; m < NVMTL_DB_MRU; m++)
        if (s->mru[which][m].plan == pl && s->mru[which][m].gen == s->gen && s->mru[which][m].epoch == s->epoch[which]
            && nvmtl_tabneed_covers(s->mru[which][m].need, need)) {
            s->plan[which] = pl; s->off[which] = s->mru[which][m].off; s->ogen[which] = s->gen; s->oepoch[which] = s->epoch[which]; s->oneed[which] = s->mru[which][m].need;
            s->n_reuse++; return 0;
        }
    uint32_t off = 0;
    uint8_t *dst = nvmtl_db_alloc(s, pl->size, &off);
    if (!dst) return -1;
    for (uint32_t k = 0; k < pl->n; k++) {
        const nvmtl_dbent *e = &pl->e[k];
        const uint32_t i = e->slot, sz = g_dbt_size[e->type];
        if (i == NVMTL_ADDRESS_BINDING) {   // a new table for a new region: it holds the stage's buffer addresses and texture sizes
            VkDescriptorBufferInfo ai;
            c->tab_need[which] = need;
            if (nvmtl_address_snapshot(c, which, &ai)) return -1;
            const uint8_t *td = nvmtl_db_table_desc(c, e->type, &ai);
            if (!td) return -1;
            memcpy(dst + e->off, td, sz);
            continue;
        }
        uint8_t *sh = s->d[which][i];
        if (!((s->valid[which][i >> 6] >> (i & 63)) & 1) || s->ty[which][i] != e->type) {
            nvmtl_db_gen(t ? &t->s[which][i] : NULL, which, i, e->type, sh);
            s->valid[which][i >> 6] |= 1ull << (i & 63); s->ty[which][i] = e->type;
            s->n_gen++;
        }
        memcpy(dst + e->off, sh, sz);
    }
    s->plan[which] = pl; s->off[which] = off; s->ogen[which] = s->gen; s->oepoch[which] = s->epoch[which]; s->oneed[which] = need;
    const uint32_t m = s->mru_next[which]++ % NVMTL_DB_MRU;
    s->mru[which][m].plan = pl; s->mru[which][m].off = off; s->mru[which][m].gen = s->gen; s->mru[which][m].epoch = s->epoch[which]; s->mru[which][m].need = need;
    s->n_reg++;
    return 0;
}
/* the offsets for the n sets of layout `lay` at bind point bp (0 graphics, 1 compute); skipped when already set */
static void nvmtl_db_set_offsets(nvk_cmdbuf *c, nvmtl_dbstate *s, int bp, VkPipelineLayout lay, uint32_t n,
                                 const uint32_t *idx, const uint32_t *off)
{
    int same = s->lay[bp] == lay && s->lgen[bp] == s->gen && s->nset[bp] == n;
    for (uint32_t k = 0; same && k < n; k++) same = s->sidx[bp][k] == idx[k] && s->soff[bp][k] == off[k];
    if (same) return;
    VkDeviceSize o[4];
    for (uint32_t k = 0; k < n; k++) o[k] = off[k];
    pvkCmdSetDescriptorBufferOffsetsEXT((VkCommandBuffer)c->cb, bp ? VK_PIPELINE_BIND_POINT_COMPUTE : VK_PIPELINE_BIND_POINT_GRAPHICS,
                                        lay, 0, n, idx, o);
    s->lay[bp] = lay; s->lgen[bp] = s->gen; s->nset[bp] = n;
    for (uint32_t k = 0; k < n; k++) { s->sidx[bp][k] = idx[k]; s->soff[bp][k] = off[k]; }
}
static uint32_t nvmtl_db_worst(const nvmtl_dbplan *a, const nvmtl_dbplan *b, uint32_t extra)
{
    const uint32_t al = g_db_align ? g_db_align : 64;
    return a->size + b->size + extra + 3 * al;
}

/* Graphics: nvmtl_vk_cmd_bind_set in the buffer model. Sets 0 and 1 are the stages, 2 the heap (an empty layout when
   only set 3 is used and there is no heap), 3 framebuffer fetch. */
__attribute__((noinline)) static void nvmtl_db_cmd_bind_set(nvk_cmdbuf *c, nvk_pipeline *p)
{
    nvmtl_dbstate *s = nvmtl_db_state(c);
    const nvmtl_dbplan *pl0 = (const nvmtl_dbplan *)p->dbplan[0], *pl1 = (const nvmtl_dbplan *)p->dbplan[1];
    const int fetch_draw = p->fetch_mask && c->in_rp && !p->skip_draws, fetch = fetch_draw || p->fetch_zero;
    if (fetch) { pthread_mutex_lock(&g_desc_lock); nvmtl_db_fetch_offsets_locked(); pthread_mutex_unlock(&g_desc_lock); }
    uint32_t foff = 0;
    if (!s || !pl0 || !pl1 || (fetch && (!g_db_fetch_ready || !g_dummyImg.view)) ||
        nvmtl_db_reserve(s, nvmtl_db_worst(pl0, pl1, fetch ? g_db_fetch_size : 0)) ||
        nvmtl_db_stage(c, s, 0, pl0, p->tabneed[0]) || nvmtl_db_stage(c, s, 1, pl1, p->tabneed[1])) goto fail;
    if (fetch_draw || (p->fetch_zero && s->fz_gen != s->gen)) {
        uint8_t *dst = nvmtl_db_alloc(s, g_db_fetch_size, &foff);
        if (!dst) goto fail;
        const uint32_t mask = fetch_draw ? p->fetch_mask : (1u << NVMTL_NCOL) - 1;
        for (uint32_t i = 0; i < NVMTL_NCOL; i++) {
            if (!(mask & (1u << i))) continue;
            // as nvmtl_fetch_set / nvmtl_fetch_zero_set: a colour attachment the pass does not have reads the dummy
            const int have = fetch_draw && c->fetchview[i];
            nvmtl_db_get_image(NVMTL_DBT_INPUT, have ? c->fetchview[i] : g_dummyImg.view,
                               have ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, dst + g_db_fetch_off[i]);
        }
        if (!fetch_draw) { s->fz_off = foff; s->fz_gen = s->gen; }
    } else if (p->fetch_zero) foff = s->fz_off;
    c->nobind = 0;
    nvmtl_db_bind_buffers(c, s);
    if (g_sample_locations && c->sample_pattern.count)
        pvkCmdPushConstants(c->cb, (VkPipelineLayout)p->layout, VK_SHADER_STAGE_FRAGMENT_BIT, NVMTL_SAMPLE_POSITION_OFFSET,
                           NVMTL_SAMPLE_POSITION_BYTES, c->sample_pattern.position);
    const uint32_t idx[4] = { 0, 0, g_heap_ready ? 1u : 0u, 0 }, off[4] = { s->off[0], s->off[1], 0, foff };
    nvmtl_db_set_offsets(c, s, 0, (VkPipelineLayout)p->layout, fetch ? 4u : g_heap_ready ? 3u : 2u, idx, off);
    c->semu_layout = p->stencil_emu ? p->layout : NULL;
    c->fetch_draw = 0;
    if (p->skip_draws) { c->nobind = 1; return; }
    if (fetch_draw) { nvmtl_fetch_barrier(c); c->fetch_draw = 1; }
    return;
fail:
    { static int said; if (said++ < 4) nvlog("vk: descriptor buffer: no descriptor memory for a draw - it is not recorded"); }
    // counted: the command buffer then ends with an error instead of running without the draw (fix30)
    c->skipped++; c->skip_oom++; c->nobind = 1;
}
/* Compute: the sets of the nvmtl_vk_cmd_dispatch* calls in the buffer model. 0, or -1 (the dispatch is not recorded) */
__attribute__((noinline)) static int nvmtl_db_bind_compute(nvk_cmdbuf *c, const nvk_pipeline *p)
{
    nvmtl_dbstate *s = nvmtl_db_state(c);
    const nvmtl_dbplan *pl0 = (const nvmtl_dbplan *)p->dbplan[0], *pl1 = (const nvmtl_dbplan *)p->dbplan[1];
    if (!s || !pl0 || !pl1 || nvmtl_db_reserve(s, nvmtl_db_worst(pl0, pl1, 0)) ||
        nvmtl_db_stage(c, s, 0, pl0, p->tabneed[0]) || nvmtl_db_stage(c, s, 1, pl1, p->tabneed[1])) {
        static int said; if (said++ < 4) nvlog("vk: descriptor buffer: no descriptor memory for a dispatch - it is not recorded");
        c->skipped++; c->skip_oom++; c->nobind = 1; return -1;
    }
    c->nobind = 0;
    nvmtl_db_bind_buffers(c, s);
    const uint32_t idx[3] = { 0, 0, g_heap_ready ? 1u : 0u }, off[3] = { s->off[0], s->off[1], 0 };
    nvmtl_db_set_offsets(c, s, 1, (VkPipelineLayout)p->layout, g_heap_ready ? 3u : 2u, idx, off);
    return 0;
}
/* NVMTL_DBUF_CENSUS=1: the totals, at every 256th retired command buffer that used the model */
static void nvmtl_db_census(void)
{
    static int on = -1; if (on < 0) { const char *e = getenv("NVMTL_DBUF_CENSUS"); on = e && e[0] == '1'; }
    static _Atomic unsigned long long retired;
    if (!on || (atomic_fetch_add(&retired, 1) & 255)) return;
    const unsigned long long n = atomic_load(&g_db_regions);
    nvlog("vk: descriptor buffer census: %llu regions, %llu reused, %llu descriptors made, %llu pages (+%llu large), %u layouts",
          n, (unsigned long long)atomic_load(&g_db_reuse), (unsigned long long)atomic_load(&g_db_gen),
          (unsigned long long)atomic_load(&g_db_pages), (unsigned long long)atomic_load(&g_db_bigpages), g_dbplan_n);
}
