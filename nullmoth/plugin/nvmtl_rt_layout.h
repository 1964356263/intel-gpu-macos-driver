/* nvmtl_rt_layout.h: what a Metal acceleration structure holds besides the Vulkan one (rtopt4). Shared by the plugin
   (writes it at build time), nvmtl_rt_instances.comp / nvmtl_rt_curves.comp (GPU passes) and the translator's ray
   tracing runtime (nvmtl_rt_runtime.metal, embedded as LLVM text: reads it from shaders through the structure's address).

   A Metal acceleration structure's buffer: [NVMTL_AS_HEADER bytes: header][the Vulkan acceleration structure]. Its
   address (gpuResourceID, argument buffers, setAccelerationStructure bindings) is the header's; the Vulkan structure
   (ray queries, instance references) is at + NVMTL_AS_HEADER. Metal-visible sizes are the Vulkan ones (the header is
   allocated on top).
   primitive structure: table = one nvmtl_geom_rec per geometry (geometry_id order)
   instance structure:  table = one nvmtl_inst_rec per instance (instance_id order)

   rtopt5: what shaders trace at + NVMTL_AS_HEADER is a TOP-level structure for both kinds. A primitive structure's
   buffer is [header][NVMTL_AS_WRAP: a one-instance top-level structure (identity transform, mask 0xFF, flags 0,
   custom index 0) over the bottom-level one][the bottom-level structure]; its Metal-visible size (sizes, compacted
   size) includes NVMTL_AS_WRAP. Vulkan ray queries start at a top-level structure; ANV's ray query code continues
   traversal, generates hits and reads the candidate's object-space ray at the instance (object) level only, so a
   bottom-level root worked only while every hit was an opaque triangle (no candidate returned to the shader).
   Instances reference the bottom-level structure (Metal address + NVMTL_AS_HEADER + NVMTL_AS_WRAP); the header's vk
   is its address. NVMTL_RT_WRAP=0 (environment) keeps the rtopt4 layout (bottom-level structure at + NVMTL_AS_HEADER). */
#ifndef NVMTL_RT_LAYOUT_H
#define NVMTL_RT_LAYOUT_H
#include <stdint.h>
#define NVMTL_AS_HEADER 256u
#define NVMTL_AS_WRAP 1024u              /* ANV: a one-instance top-level structure is 512 bytes (checked at init) */
#define NVMTL_AS_MAGIC 0x5341564eu            /* 'NVAS' */
#define NVMTL_AS_FLAG_CURVES 1u
#define NVMTL_AS_FLAG_PRIMITIVE_DATA 2u
typedef struct { uint32_t magic, kind, count, flags; uint64_t table, vk; uint32_t rec_bytes, pad[7]; } nvmtl_as_header;   /* kind 0 primitive, 1 instance */
/* kind: 0 triangle, 1 bounding box, 2 curve. ift: the geometry's intersectionFunctionTableOffset. pd: primitive data
   (buffer address + offset, 0 none), element of primitive p at pd + p * pd_stride. Curve: cp / radius / index buffer
   addresses (+ offsets), Metal's MTLAttributeFormat of control points and radii, index_type MTLIndexType (0 UInt16,
   1 UInt32): segment s starts at control point index[s]; seg_cp segmentControlPointCount, basis MTLCurveBasis, ctype
   MTLCurveType, caps MTLCurveEndCaps, cp_count controlPointCount (a segment's first index is clamped to
   cp_count - seg_cp: no read past the control points). */
typedef struct { uint32_t kind, ift, pd_stride, pd_size; uint64_t pd, cp, radius, index;
                 uint32_t cp_stride, cp_format, r_stride, r_format, index_type, seg_cp, basis, ctype, caps, seg_count, cp_count, pad; } nvmtl_geom_rec;
/* blas: the instanced primitive structure's address (its header; 0 = none / inactive), user: Metal's 32-bit user ID,
   ift: the instance's intersectionFunctionTableOffset */
typedef struct { uint64_t blas; uint32_t user, ift; } nvmtl_inst_rec;
#if defined(__STDC_VERSION__) || defined(__cplusplus)
_Static_assert(sizeof(nvmtl_as_header) == 64, "header");
_Static_assert(sizeof(nvmtl_geom_rec) == 96, "geometry record");
_Static_assert(sizeof(nvmtl_inst_rec) == 16, "instance record");
#endif
#endif
