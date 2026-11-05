# Taşınacaklar / What we must port

Üretildi / generated: `tools/parity/consumers.py` (`tools/parity/build.sh`). Kaynak: `data/uapi.json`.

**TR:** Sıra: önce bugün çalıştırdığımız yazılımın (Mesa ANV ve ortak Intel kodu; eklenti ve VideoToolbox kodunda xe uAPI kullanımı yok) kullandığı ama çekirdeğimizin uygulamadığı xe uAPI ögeleri (kırmızı), sonra yalnızca gelecekteki bir hedefin (OpenCL/oneAPI, profiler, iris) kullandığı ögeler (turuncu), özelliğe göre gruplu. Her satır tüketicinin `dosya:satır` kanıtını taşır; "bizde" sütunu çekirdeğimizdeki durumdur (`uapi.py`). xemac tüketici sayılmaz: ioctl'ları çekirdeğe ileten katmandır.

**EN:** Order: first the xe uAPI items the user space we run today uses but our kernel does not implement (red), then items only a future target uses (orange), grouped by feature. Each row cites the consumer file:line.

Aranan ağaçlar / trees searched:

- Mesa ANV / intel common (as run on macOS) @ a3ad934832bb (193 files)
- Metal plugin / VideoToolbox (this repository) @ 030bfaed7ca8 (44 files)
- iris (Mesa) @ a3ad934832bb (57 files)
- Mesa intel/perf @ a3ad934832bb (18 files)
- Intel compute-runtime (NEO) @ 248eb54f8441 (137 files)

## 1. Şimdi gerekli, eksik / Needed now, missing (2)

| # | Öge / item | Bizde / ours | Ne işe yarar / what it is (xe_drm.h) | Tüketici / consumer (file:line) |
|---|---|---|---|---|
| 1 | `DRM_XE_QUERY_CONFIG_FLAG_HAS_PURGING_SUPPORT` | rapor edilmiyor — kernel/IntelXe/xe_core.cpp:3431 | value of a field in struct drm_xe_query_config | Mesa ANV / intel common (as run on macOS): src/intel/dev/xe/intel_device_info.c:82 |
| 2 | `DRM_XE_GEM_CREATE_EXTENSION_SET_PROPERTY` | doğrulanmadı | value of a field in struct drm_xe_gem_create | Mesa ANV / intel common (as run on macOS): src/intel/vulkan/xe/anv_kmd_backend.c:72 |

## 2. Gelecek hedefler için / Needed for a future target (63)

### OpenCL / oneAPI (Intel compute-runtime) (35)

| Öge / item | Bizde / ours | Tüketici / consumer (file:line) |
|---|---|---|
| `DRM_IOCTL_XE_WAIT_USER_FENCE` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:2339 |
| `DRM_IOCTL_XE_OBSERVATION` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe_perf.cpp:118 |
| `DRM_IOCTL_XE_MADVISE` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:2327 |
| `DRM_IOCTL_XE_VM_QUERY_MEM_RANGE_ATTRS` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:2329 |
| `DRM_IOCTL_XE_EXEC_QUEUE_SET_PROPERTY` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:2337 |
| `DRM_XE_QUERY_CONFIG_FLAG_HAS_CPU_ADDR_MIRROR` | rapor edilmiyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:189 |
| `DRM_XE_DEVICE_QUERY_EU_STALL` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe_perf.cpp:54 |
| `DRM_XE_GEM_CREATE_FLAG_DEFER_BACKING` | doğrulanmadı | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:750 |
| `DRM_XE_MMAP_OFFSET_FLAG_PCI_BARRIER` | doğrulanmadı | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:2436 |
| `DRM_XE_CONSULT_MEM_ADVISE_PREF_LOC` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1159 |
| `DRM_XE_EXEC_QUEUE_SET_PROPERTY_MULTI_GROUP` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:2240 |
| `DRM_XE_MULTI_GROUP_CREATE` | doğrulanmadı | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:2277 |
| `DRM_XE_EXEC_QUEUE_SET_PROPERTY_MULTI_QUEUE_PRIORITY` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:2266 |
| `DRM_XE_EXEC_QUEUE_BAN_REASON_PAGE_OFFLINE` | doğrulanmadı | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1407 |
| `DRM_XE_SYNC_TYPE_USER_FENCE` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1236, shared/source/os_interface/linux/xe/ioctl_helper_xe_debugger.cpp:267 |
| `DRM_XE_UFENCE_WAIT_OP_EQ` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1927, shared/source/os_interface/linux/xe/ioctl_helper_xe_debugger.cpp:298 |
| `DRM_XE_UFENCE_WAIT_OP_NEQ` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:873 |
| `DRM_XE_UFENCE_WAIT_OP_GTE` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:857 |
| `DRM_XE_EU_STALL_EXTENSION_SET_PROPERTY` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe_perf.cpp:104 |
| `DRM_XE_MEM_RANGE_ATTR_PREFERRED_LOC` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:84 |
| `DRM_XE_MEM_RANGE_ATTR_ATOMIC` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:86 |
| `DRM_XE_MEM_RANGE_ATTR_PAT` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:88 |
| `DRM_XE_PREFERRED_LOC_DEFAULT_DEVICE` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1459 |
| `DRM_XE_PREFERRED_LOC_DEFAULT_SYSTEM` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1461 |
| `DRM_XE_MIGRATE_ALL_PAGES` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1463 |
| `DRM_XE_MIGRATE_ONLY_SYSTEM_PAGES` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1465 |
| `DRM_XE_ATOMIC_UNDEFINED` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1447 |
| `DRM_XE_ATOMIC_DEVICE` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1449 |
| `DRM_XE_ATOMIC_GLOBAL` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1451 |
| `DRM_XE_ATOMIC_CPU` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe.cpp:1453 |
| `DRM_XE_OBSERVATION_TYPE_EU_STALL` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe_perf.cpp:96 |
| `DRM_XE_OBSERVATION_OP_STREAM_OPEN` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe_perf.cpp:97 |
| `DRM_XE_EU_STALL_PROP_GT_ID` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe_perf.cpp:88 |
| `DRM_XE_EU_STALL_PROP_SAMPLE_RATE` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe_perf.cpp:84 |
| `DRM_XE_EU_STALL_PROP_WAIT_NUM_REPORTS` | reddediliyor | Intel compute-runtime (NEO): shared/source/os_interface/linux/xe/ioctl_helper_xe_perf.cpp:86 |

### GPU profiler (OA metrics, VK_KHR_performance_query) (32)

| Öge / item | Bizde / ours | Tüketici / consumer (file:line) |
|---|---|---|
| `DRM_IOCTL_XE_OBSERVATION` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:206 |
| `DRM_XE_DEVICE_QUERY_OA_UNITS` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:144 |
| `DRM_XE_DEVICE_QUERY_EU_STALL` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:535 |
| `DRM_XE_OA_CAPS_SYNCS` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:165 |
| `DRM_XE_OA_EXTENSION_SET_PROPERTY` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:230 |
| `DRM_XE_OA_FORMAT_MASK_FMT_TYPE` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:94 |
| `DRM_XE_OA_FORMAT_MASK_COUNTER_SEL` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:95 |
| `DRM_XE_OA_FORMAT_MASK_COUNTER_SIZE` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:96 |
| `DRM_XE_OA_FORMAT_MASK_BC_REPORT` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:97 |
| `DRM_XE_OASTATUS_MMIO_TRG_Q_FULL` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:429 |
| `DRM_XE_OASTATUS_COUNTER_OVERFLOW` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:427 |
| `DRM_XE_OASTATUS_REPORT_LOST` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:425 |
| `DRM_XE_OBSERVATION_TYPE_OA` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:185 |
| `DRM_XE_OBSERVATION_TYPE_EU_STALL` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:503 |
| `DRM_XE_OBSERVATION_OP_STREAM_OPEN` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:260 |
| `DRM_XE_OBSERVATION_OP_ADD_CONFIG` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:186 |
| `DRM_XE_OBSERVATION_OP_REMOVE_CONFIG` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:216 |
| `DRM_XE_OA_FMT_TYPE_OAG` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:104 |
| `DRM_XE_OA_FMT_TYPE_PEC` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:94 |
| `DRM_XE_OA_PROPERTY_SAMPLE_OA` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:281 |
| `DRM_XE_OA_PROPERTY_OA_METRIC_SET` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:282 |
| `DRM_XE_OA_PROPERTY_OA_FORMAT` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:283 |
| `DRM_XE_OA_PROPERTY_OA_PERIOD_EXPONENT` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:284 |
| `DRM_XE_OA_PROPERTY_OA_DISABLED` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:280 |
| `DRM_XE_OA_PROPERTY_EXEC_QUEUE_ID` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:274 |
| `DRM_XE_OA_PROPERTY_NO_PREEMPT` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:257 |
| `DRM_XE_OA_PROPERTY_NUM_SYNCS` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:289 |
| `DRM_XE_OA_PROPERTY_SYNCS` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:290 |
| `DRM_XE_OA_PROPERTY_OA_BUFFER_SIZE` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:277 |
| `DRM_XE_EU_STALL_PROP_GT_ID` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:514 |
| `DRM_XE_EU_STALL_PROP_SAMPLE_RATE` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:512 |
| `DRM_XE_EU_STALL_PROP_WAIT_NUM_REPORTS` | reddediliyor | Mesa intel/perf: src/intel/perf/xe/intel_perf.c:501 |

### native OpenGL via iris (4)

| Öge / item | Bizde / ours | Tüketici / consumer (file:line) |
|---|---|---|
| `DRM_IOCTL_XE_MADVISE` | reddediliyor | iris (Mesa): src/gallium/drivers/iris/xe/iris_kmd_backend.c:225 |
| `DRM_XE_VMA_ATTR_PURGEABLE_STATE` | reddediliyor | iris (Mesa): src/gallium/drivers/iris/xe/iris_kmd_backend.c:218 |
| `DRM_XE_VMA_PURGEABLE_STATE_WILLNEED` | reddediliyor | iris (Mesa): src/gallium/drivers/iris/xe/iris_kmd_backend.c:220 |
| `DRM_XE_VMA_PURGEABLE_STATE_DONTNEED` | reddediliyor | iris (Mesa): src/gallium/drivers/iris/xe/iris_kmd_backend.c:221 |

## 3. Diğer Intel GPU'ları (gelecek donanım hedefleri) / Other Intel GPUs (future hardware targets)

Linux xe / i915 display dosyaları; B580'de olmayan ama başka bir Intel ailesinde bulunan donanım için. Platform ve gerekçe `tools/parity/map.json`'dan (Linux kaynağındaki koşula dayanarak). / Files for hardware another Intel family has; platform and reason from map.json, based on the condition in the Linux source.

| Platform | Dosya / files | Fonksiyon / functions | Satır / lines | Gerekçe / reason |
|---|---|---|---|---|
| Intel iGPU laptops TGL…PTL (eDP / DSI panels) | 34 | 772 | 18777 | internal-panel features (eDP/DSI, PSR, panel power, backlight, OpRegion); the B580 has no internal panel |
| Intel iGPUs TGL…PTL (Type-C / Thunderbolt) | 4 | 186 | 3226 | Type-C/TBT subsystem; intel_phy_is_tc() is false on dGPU (intel_display.c) |
| NVL (LT PHY) | 3 | 65 | 2502 | intel_display_device.h: HAS_LT_PHY = platform.novalake |
| Intel iGPUs with a GSC: MTL, LNL, PTL, NVL | 16 | 86 | 2298 | GSC microcontroller; xe_uc_fw.c XE_GSC_FIRMWARE_DEFS lists NVL-S, PTL, LNL, MTL (BMG has none) |
| DG2 / Alchemist (SNPS PHY) | 3 | 19 | 2099 | intel_ddi.c: snps signal levels when platform.dg2 |
| Crescent Island (CRI) | 10 | 31 | 1058 | system controller: xe_pci.c sets has_sysctrl only in cri_desc |
| Intel iGPUs TGL…PTL (system-memory bandwidth) | 4 | 62 | 1009 | DRAM/MCHBAR bandwidth info used by integrated displays |
| Gen12 TGL / RKL / ADL / DG1 (combo and Dekel PHYs) | 6 | 28 | 953 | PHY selection in intel_ddi.c: combo PHY for DISPLAY_VER >= 12 before 14; Dekel for TGL/ADL Type-C |
| display 30+ (PTL) | 2 | 37 | 502 | intel_flipq.c: DISPLAY_VER >= 30 checks (BMG is 14) |
| display 20+ (LNL, PTL) | 3 | 13 | 295 | intel_display_device.h: HAS_CASF = DISPLAY_VER >= 20 (BMG is 14) |

### Intel iGPU laptops TGL…PTL (eDP / DSI panels)

`display/intel_psr.c` (4675), `display/icl_dsi.c` (2044), `display/intel_pps.c` (1873), `display/intel_backlight.c` (1856), `display/intel_opregion.c` (1306), `display/intel_dsi_vbt.c` (960), `display/intel_alpm.c` (772), `display/intel_dp_aux_backlight.c` (762), `display/intel_pfit.c` (753), `display/intel_panel.c` (695), `display/intel_drrs.c` (421), `display/intel_acpi.c` (363), `display/intel_psr_regs.h` (345), `display/icl_dsi_regs.h` (344), `display/intel_dsi_dcs_backlight.c` (206), `display/intel_dsi_vbt_defs.h` (197), `display/intel_dsi.h` (177), `display/intel_opregion.h` (145), `display/intel_dsi.c` (131), `display/intel_backlight_regs.h` (121), `display/intel_psr.h` (92), `display/intel_pfit_regs.h` (79), `display/intel_pps_regs.h` (77), `display/intel_pps.h` (67), `display/intel_panel.h` (63), `display/intel_backlight.h` (52), `display/intel_alpm.h` (45), `display/intel_drrs.h` (33), `display/intel_acpi.h` (31), `display/intel_pfit.h` (29), `display/intel_dsi_vbt.h` (20), `display/icl_dsi.h` (17), `display/intel_dp_aux_backlight.h` (13), `display/intel_dsi_dcs_backlight.h` (13)

### Intel iGPUs TGL…PTL (Type-C / Thunderbolt)

`display/intel_tc.c` (2024), `display/intel_dp_tunnel.c` (924), `display/intel_dp_tunnel.h` (159), `display/intel_tc.h` (119)

### NVL (LT PHY)

`display/intel_lt_phy.c` (2359), `display/intel_lt_phy_regs.h` (90), `display/intel_lt_phy.h` (53)

### Intel iGPUs with a GSC: MTL, LNL, PTL, NVL

`xe/xe_gsc.c` (628), `xe/xe_gsc_proxy.c` (559), `xe/xe_heci_gsc.c` (248), `xe/xe_gsc_submit.c` (218), `xe/display/xe_hdcp_gsc.c` (217), `xe/xe_gsc_types.h` (76), `xe/regs/xe_gsc_regs.h` (58), `xe/abi/gsc_command_header_abi.h` (46), `xe/abi/gsc_proxy_commands_abi.h` (44), `xe/xe_heci_gsc.h` (40), `xe/abi/gsc_mkhi_commands_abi.h` (39), `xe/instructions/xe_gsc_commands.h` (36), `xe/xe_gsc_submit.h` (32), `xe/xe_gsc.h` (27), `xe/xe_gsc_proxy.h` (21), `xe/display/xe_hdcp_gsc.h` (9)

### DG2 / Alchemist (SNPS PHY)

`display/intel_snps_phy.c` (1984), `display/intel_snps_phy_regs.h` (75), `display/intel_snps_phy.h` (40)

### Crescent Island (CRI)

`xe/xe_sysctrl_mailbox.c` (390), `xe/xe_sysctrl.c` (219), `xe/xe_sysctrl_mailbox_types.h` (123), `xe/xe_sysctrl_event.c` (76), `xe/abi/xe_sysctrl_abi.h` (65), `xe/xe_sysctrl_event_types.h` (54), `xe/xe_sysctrl_types.h` (36), `xe/regs/xe_sysctrl_regs.h` (36), `xe/xe_sysctrl_mailbox.h` (33), `xe/xe_sysctrl.h` (26)

### Intel iGPUs TGL…PTL (system-memory bandwidth)

`display/intel_dram.c` (867), `display/intel_mchbar.c` (78), `display/intel_dram.h` (43), `display/intel_mchbar.h` (21)

### Gen12 TGL / RKL / ADL / DG1 (combo and Dekel PHYs)

`display/intel_combo_phy.c` (417), `display/intel_dkl_phy_regs.h` (207), `display/intel_combo_phy_regs.h` (167), `display/intel_dkl_phy.c` (117), `display/intel_dkl_phy.h` (25), `display/intel_combo_phy.h` (20)

### display 30+ (PTL)

`display/intel_flipq.c` (465), `display/intel_flipq.h` (37)

### display 20+ (LNL, PTL)

`display/intel_casf.c` (245), `display/intel_casf_regs.h` (33), `display/intel_casf.h` (17)

Gerekmeyen eski platformlar / pre-Gen12 platforms, not needed: 81 dosya, 36912 satır (platforms before Gen12 (i915 only, outside the xe driver; our strategy covers xe-supported families)).

## 4. macOS'ta gerekmiyor / Not needed on macOS (40)

Linux'a özgü kavramlar (PXP, RAS) ya da hiçbir tüketicide geçmeyen ögeler. / Linux-only concepts or no consumer found.

`DRM_XE_TOPO_EU_PER_DSS`, `DRM_XE_DEVICE_QUERY_PXP_STATUS`, `DRM_XE_GEM_CREATE_SET_PROPERTY_PXP_TYPE`, `DRM_XE_EXEC_QUEUE_SET_HANG_REPLAY_STATE`, `DRM_XE_EXEC_QUEUE_BAN_REASON_GPU_HANG`, `DRM_XE_UFENCE_WAIT_OP_GT`, `DRM_XE_UFENCE_WAIT_OP_LT`, `DRM_XE_UFENCE_WAIT_OP_LTE`, `DRM_XE_UFENCE_WAIT_FLAG_ABSTIME`, `DRM_XE_OA_CAPS_BASE`, `DRM_XE_OA_CAPS_OA_BUFFER_SIZE`, `DRM_XE_OA_CAPS_WAIT_NUM_REPORTS`, `DRM_XE_OA_CAPS_OAM`, `DRM_XE_OA_CAPS_OA_UNIT_GT_ID`, `DRM_XE_OASTATUS_BUFFER_OVERFLOW`, `DRM_XE_PXP_HWDRM_DEFAULT_SESSION`, `DRM_XE_EU_STALL_CAPS_BASE`, `DRM_XE_RAS_ERROR_SEVERITY_NAMES`, `DRM_XE_RAS_ERROR_COMPONENT_NAMES`, `DRM_XE_OA_UNIT_TYPE_OAG`, `DRM_XE_OA_UNIT_TYPE_OAM`, `DRM_XE_OA_UNIT_TYPE_OAM_SAG`, `DRM_XE_OA_UNIT_TYPE_MERT`, `DRM_XE_OA_FMT_TYPE_OAR`, `DRM_XE_OA_FMT_TYPE_OAM`, `DRM_XE_OA_FMT_TYPE_OAC`, `DRM_XE_OA_FMT_TYPE_OAM_MPEC`, `DRM_XE_OA_PROPERTY_OA_UNIT_ID`, `DRM_XE_OA_PROPERTY_OA_ENGINE_INSTANCE`, `DRM_XE_OA_PROPERTY_WAIT_NUM_REPORTS`, `DRM_XE_PXP_TYPE_HWDRM`, `DRM_XE_RAS_ERR_SEV_CORRECTABLE`, `DRM_XE_RAS_ERR_SEV_UNCORRECTABLE`, `DRM_XE_RAS_ERR_SEV_MAX`, `DRM_XE_RAS_ERR_COMP_CORE_COMPUTE`, `DRM_XE_RAS_ERR_COMP_SOC_INTERNAL`, `DRM_XE_RAS_ERR_COMP_DEVICE_MEMORY`, `DRM_XE_RAS_ERR_COMP_PCIE`, `DRM_XE_RAS_ERR_COMP_FABRIC`, `DRM_XE_RAS_ERR_COMP_MAX`

