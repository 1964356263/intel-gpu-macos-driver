// SPDX-License-Identifier: MIT
/*
 * Contains material from Linux drivers/gpu/drm/xe: xe_guc_fwif.h, abi/guc_capture_abi.h,
 * abi/guc_scheduler_abi.h, abi/uc_fw_abi.h and xe_guc_ads.c.
 *
 * Copyright © 2021-2024 Intel Corporation
 * Copyright (c) 2026 Yusuf İhsan Kılınç (this adaptation)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
// GuC ABI pieces for the minimal ADS, copied from Linux v7.2 drivers/gpu/drm/xe (MIT, Copyright Intel Corporation):
// xe_guc_fwif.h (guc_policies, guc_gt_system_info, guc_ads, guc_engine_usage*, guc_um_*, GUC_CTL_*),
// abi/guc_capture_abi.h (guc_mmio_reg_set), abi/guc_scheduler_abi.h (class/instance limits),
// abi/uc_fw_abi.h (uc_css_header), xe_guc_ads.c (__guc_ads_blob).
#pragma once
#include <stdint.h>

#define GUC_MAX_ENGINE_CLASSES 16
#define GUC_MAX_INSTANCES_PER_CLASS 32
#define GUC_GENERIC_GT_SYSINFO_MAX 16
#define GUC_CAPTURE_LIST_INDEX_MAX 2
#define GUC_UM_HW_QUEUE_MAX 3

#define GLOBAL_POLICY_MAX_NUM_WI 15
#define GLOBAL_POLICY_DEFAULT_DPC_PROMOTE_TIME_US 500000

#define GUC_CTL_LOG_PARAMS 0
#define GUC_CTL_WA 1
#define GUC_CTL_FEATURE 2
#define GUC_CTL_DEBUG 3
#define   GUC_LOG_DISABLED (1u << 6)
#define GUC_CTL_ADS 4             // GUC_ADS_ADDR 21:1 = GGTT address >> 12
#define GUC_CTL_DEVID 5
#define GUC_CTL_MAX_DWORDS 14

struct guc_mmio_reg_set {
	uint32_t address;
	uint16_t count;
	uint16_t reserved;
} __attribute__((packed));

struct guc_policies {
	uint32_t submission_queue_depth[GUC_MAX_ENGINE_CLASSES];
	uint32_t dpc_promote_time;
	uint32_t is_valid;
	uint32_t max_num_work_items;
	uint32_t global_flags;
	uint32_t reserved[4];
} __attribute__((packed));

struct guc_gt_system_info {
	uint8_t mapping_table[GUC_MAX_ENGINE_CLASSES][GUC_MAX_INSTANCES_PER_CLASS];
	uint32_t engine_enabled_masks[GUC_MAX_ENGINE_CLASSES];
	uint32_t generic_gt_sysinfo[GUC_GENERIC_GT_SYSINFO_MAX];
} __attribute__((packed));

struct guc_ads {
	struct guc_mmio_reg_set reg_state_list[GUC_MAX_ENGINE_CLASSES][GUC_MAX_INSTANCES_PER_CLASS];
	uint32_t reserved0;
	uint32_t scheduler_policies;
	uint32_t gt_system_info;
	uint32_t reserved1;
	uint32_t control_data;
	uint32_t golden_context_lrca[GUC_MAX_ENGINE_CLASSES];
	uint32_t eng_state_size[GUC_MAX_ENGINE_CLASSES];
	uint32_t private_data;
	uint32_t um_init_data;
	uint32_t capture_instance[GUC_CAPTURE_LIST_INDEX_MAX][GUC_MAX_ENGINE_CLASSES];
	uint32_t capture_class[GUC_CAPTURE_LIST_INDEX_MAX][GUC_MAX_ENGINE_CLASSES];
	uint32_t capture_global[GUC_CAPTURE_LIST_INDEX_MAX];
	uint32_t wa_klv_addr_lo;
	uint32_t wa_klv_addr_hi;
	uint32_t wa_klv_size;
	uint32_t reserved[11];
} __attribute__((packed));

struct guc_engine_usage_record {
	uint32_t current_context_index;
	uint32_t last_switch_in_stamp;
	uint32_t reserved0;
	uint32_t total_runtime;
	uint32_t reserved1[4];
} __attribute__((packed));

struct guc_engine_usage {
	struct guc_engine_usage_record engines[GUC_MAX_ENGINE_CLASSES][GUC_MAX_INSTANCES_PER_CLASS];
} __attribute__((packed));

struct guc_um_queue_params {
	uint64_t base_dpa;
	uint32_t base_ggtt_address;
	uint32_t size_in_bytes;
	uint32_t rsvd[4];
} __attribute__((packed));

struct guc_um_init_params {
	uint64_t page_response_timeout_in_us;
	uint32_t rsvd[6];
	struct guc_um_queue_params queue_params[GUC_UM_HW_QUEUE_MAX];
} __attribute__((packed));

struct guc_ads_blob {
	struct guc_ads ads;
	struct guc_policies policies;
	struct guc_gt_system_info system_info;
	struct guc_engine_usage engine_usage;
	struct guc_um_init_params um_init_params;
} __attribute__((packed));

struct uc_css_header {
	uint32_t module_type;
	uint32_t header_size_dw;
	uint32_t header_version;
	uint32_t reserved0;
	uint32_t module_vendor;
	uint32_t date;
	uint32_t size_dw;
	uint32_t key_size_dw, modulus_size_dw, exponent_size_dw;
	uint32_t time;
	uint32_t reserved_g0[5];
	uint32_t sw_version;
	uint32_t submission_version;
	uint32_t reserved_g1[11];
	uint32_t header_info;
	uint32_t private_data_size;
	uint32_t ukernel_info;
} __attribute__((packed));
static_assert(sizeof(struct uc_css_header) == 128, "CSS header");
