# B580 hardware video on macOS: research and plan

> Design note with its date: it records the plan and the state of that day, not the current status. The current
> state is in the README and `docs/devices/b580.md`.

Sources: Linux torvalds master `drivers/gpu/drm/xe` (fetched 2026-10-28 into `scratchpad/linux-video/`), Mesa main (local `src/mesa` checkout plus upstream `anv_physical_device.c`, which is identical in the gating lines), FFmpeg master (`scratchpad/ffmpeg-src/`), and nullmoth `plugin/NVMTLDevice.m`. **[V]** means I read it in source. **[I]** means it is my inference.

## TL;DR

- On BMG, media is a **separate GT** (gt1, MMIO adjust 0x380000) with **its own GuC instance** running the **same `bmg_guc_70.bin`**. HuC is `xe/bmg_huc.bin`. It is DMA-loaded into the media GT's WOPCM and authenticated **by the media GuC** (H2G `AUTHENTICATE_HUC`). BMG has **no GSC firmware**, so neither MEI nor GSC is needed. [V]
- ANV on Xe2 supports **decode only**: H.264, H.265 (needs HuC), AV1 (incl. film grain on Xe2), VP9 profiles 0/2. **Encode is disabled for anything newer than 12.5**, so no encode on BMG. Video also sits behind the runtime flag **`ANV_DEBUG=video-decode`**. [V]
- **First visible win:** ffmpeg `-hwaccel vulkan` **AV1/H.264 decode** on the B580, using the Khronos loader and `intel_icd.json` that nullmoth already ships. H.264 and AV1 do not need HuC. AV1 is the only codec where the B580 adds something the UHD 770 + Apple VA path cannot give macOS. [V+I]
- **VideoToolbox:** a decoder can be registered per process with the private `VTRegisterVideoDecoderWithInfo` (VTRating 1000). nullmoth already does this for NVDEC, including inside `VTDecoderXPCService`, which is where Safari and QuickTime decode. So the route is proven in this very plugin. MediaExtension (macOS 15) is not usable here: it is opt-in and only for formats the system cannot decode. [V+I]

## 1. Kernel: media GT on BMG

### Topology [V]
- `xe_pci.c`: `media_ips[] = { 1301, "Xe2_HPM", &media_xelpmp }`. `media_xelpmp.hw_engine_mask` = VCS0-7 | VECS0-3 | GSCCS0. `bmg_desc.max_gt_per_tile = 2`, `max_remote_tiles` not set (single tile).
- `xe_pci.c:alloc_primary_gt`: media engines are added to the primary GT only when `MEDIA_VER < 13`. `alloc_media_gt` creates `XE_GT_TYPE_MEDIA` with `id = tile*2+1` when `MEDIA_VER >= 13`. **13.01 means a standalone media GT (gt1).**
- `xe_gt.c:xe_gt_mmio_init`: the media GT gets `adj_offset = MEDIA_GT_GSI_OFFSET (0x380000)` and `adj_limit = MEDIA_GT_GSI_LENGTH (0x40000)` (`regs/xe_gt_regs.h`). The offset is added **only to registers below 0x40000**. This covers forcewake (0xa188/0xa540+), the GuC block (0xc000-0xc3xx, WOPCM 0xc050/0xc340, HUC_KERNEL_LOAD_INFO 0xc1dc, DMA 0xc300-0xc314), the fuse register 0x9140 and PAT 0x4800. Engine ring bases (VCS0 0x1c0000, VECS0 0x1c8000, VCS2 0x1d0000, VECS1 0x1d8000) and the GuC interrupt/doorbell block at 0x190000+ are absolute, so they are **not** offset.
- `xe_gt_mcr.c:xe_gt_mcr_init_early`: media 13.01 has its own steering tables (`xe2lpm_gpmxmt_steering_table`, `xe2lpm_instance0_steering_table`, all in 0x38xxxx). PAT on the media GT is written as plain (non-MCR) registers (`xe_pat.c` dump/program_media).

### What VCS/VECS need
- **Forcewake** [V] (`xe_force_wake.c`): the media GT has its own GT domain (`FORCEWAKE_GT` 0xa188 and `FORCEWAKE_ACK_GT_MTL` 0xdfc, both +0x380000). It has no RENDER domain (`xe_force_wake_init_engines` skips it for non-main GTs). Each present VCS *n* has `FORCEWAKE_MEDIA_VDBOX(n)` 0xa540+4n with ack 0xd50+4n, and each VECS *n* has 0xa560+4n with ack 0xd70+4n. Our kext's existing forcewake helper works if you add a GT base offset.
- **Fuses** [V]: `xe_hw_engine.c:read_media_fuses` reads `GT_VEBOX_VDBOX_DISABLE` (0x9140 on the media GT, so **0x389140**). On Xe_HP+ the bits are *enable* bits: VDBOX = bits 7:0, VEBOX = bits 19:16. **Which VCS exist on B580:** not in source. Wa_14020316580 (`xe_wa_oob.rules`: MEDIA_VERSION(1301)) is applied in `xe_gt_idle.c:xe_gt_idle_enable_pg` by clearing power gating for **VDN 0 and 2**. That strongly suggests B580 has **VCS0 + VCS2** (two MFX engines) [I]. Our `probe()` prints `rd(GT_VEBOX_VDBOX_DISABLE)` without the offset. Read 0x389140 to settle it.
- **GSCCS** [V]: `xe_uc_fw.c` `XE_GSC_FIRMWARE_DEFS` lists LNL and MTL only, **no BMG**. `check_gsc_availability` therefore drops GSCCS0. You need no GSC, no MEI and no PXP.
- **GuC for the media GT** [V]: `XE_GUC_FIRMWARE_DEFS`: `fw_def(BATTLEMAGE, GT_TYPE_ANY, … bmg 70.54.0)`, so the same binary goes to both GTs. Media-specific differences:
  - `xe_guc.c:xe_guc_comm_init_early`: the doorbell is `MED_GUC_HOST_INTERRUPT` 0x190304, not 0x1901f0.
  - MMIO H2G uses `MED_VF_SW_FLAG(n)` 0x190310+.
  - `guc_enable_irq`: the media GuC's G2H bit is in **ENGINE0_MASK** of the shared `GUC_SG_INTR_MASK` (0x1900e8). The enable bit in `GUC_SG_INTR_ENABLE` is shared, so you need a read-modify-write that does not clobber the primary.
  - The ADS must list only VIDEO and VIDEOENHANCE classes (`xe_guc_ads.c:fill_engine_enable_masks`, `guc_golden_lrc_init`). Golden LRCs for those classes are PPHWSP + 1 page (`xe_lrc.c`), using the `xe2_xcs_offsets` layout. That layout is **not** the same as `xe2_bcs_offsets`.
  - Hwconfig is fetched only on the root GT (`xe_guc_hwconfig.c:xe_guc_hwconfig_init`), so skip it on media.
  - Dynamic ICS is off on media (`xe_guc.c` ~l.621).
  - SLPC runs per GT. The media GuC reads `MTL_MPA/MPE_FREQUENCY` (`xe_guc_pc.c`).
- **HuC** [V] (`xe_huc.c`, `xe_uc.c:xe_uc_load_hw`, `xe_wopcm.c`):
  - `xe_huc_init` marks HuC NOT_SUPPORTED on any non-media GT when graphics > 12.55. HuC lives only on the media GT.
  - Firmware: `fw_def(BATTLEMAGE, GT_TYPE_ANY, no_ver(xe, huc, bmg))`, i.e. **`xe/bmg_huc.bin`**.
  - Order: `xe_huc_upload` runs **before** `xe_guc_upload` and uses `xe_uc_fw_upload(…, HUC_UKERNEL)`, the same DMA engine as GuC with DMA_CTRL bit 9 instead of UOS_MOVE.
  - `xe_wopcm_init` puts HuC at the WOPCM bottom: `guc_wopcm_base = ALIGN(huc_size + WOPCM_RESERVED_SIZE, 16K)`. `DMA_GUC_WOPCM_OFFSET` also gets `HUC_LOADING_AGENT_GUC` (bit 1). Our kext hardcodes "no HuC, GuC at 16K". The media GT has its own WOPCM registers (0x38c050/0x38c340).
  - After CT is up and SLPC has started, `xe_huc_auth(…, XE_HUC_AUTH_VIA_GUC)` sends `XE_GUC_ACTION_AUTHENTICATE_HUC` with the GGTT address of the HuC RSA (`xe_uc_fw_rsa_offset`) to the **media** GuC. It then polls `HUC_KERNEL_LOAD_INFO` (0xc1dc+0x380000) bit 0.
  - VIA_GSC needs the GSC firmware, which BMG lacks. A HuC auth failure is non-fatal in Linux.
- **Workarounds for media 13.01** [V]:
  - `xe_wa.c`:
    - Wa_16021867713 `VDBOX_CGCTL3F1C(n)` MFXPIPE_CLKGATE_DIS, per VCS.
    - Wa_14019449301 `VDBOX_CGCTL3F08(n)` CG3DDISHRS_CLKGATE_DIS, per VCS.
    - Wa_16028005424 `GUC_INTR_CHICKEN` DISABLE_SIGNALING_ENGINES.
    - Wa_16021639441 `CSFE_CHICKEN1` CSB-report disables, per engine.
    - Wa_16023105232 `RING_PSMI_CTL` RC_SEMA_IDLE_MSG_DISABLE, per engine.
  - OOB (`xe_wa_oob.rules`): 14020316580 (power gating, above), 16026508708, 14025515070, 14025883347, 14025941587. I did not trace where each one is consumed.
  - Tuning: "Stateless compression control - media" (≥1301) in `xe_tuning.c`.
  - Not applicable: 22016122933, the uncached GuC buffers, is MEDIA_VERSION(1300) only.
- **Power gating** [V]: `xe_gt_idle_enable_pg` writes `POWERGATE_ENABLE` on the media GT with MEDIA_POWERGATE_ENABLE and per-VCS VDN_HCP/VDN_MFXVDENC bits, minus VDN0/2 because of Wa_14020316580. **For bring-up, leave power gating off.**
- **Interrupts** [V] (`xe_irq.c`):
  - The same top-level `GT_INTR_DW` banks are read through tile MMIO. `pick_engine_gt` routes VIDEO_DECODE/ENHANCE and OTHER instance 16 (`OTHER_MEDIA_GUC_INSTANCE`) to the media GT.
  - Enabling: write `VCS_VECS_INTR_ENABLE` plus `VCS0_VCS1/VCS2_VCS3/VECS0_VECS1_INTR_MASK` (`xe_irq_enable_hwe` for the media GT).
  - With GuC submission only, the media GuC's G2H interrupt is the one that matters. Our irqHandle has to decode instance 16 and drain the media CT.
- **Shared-VM TLB** [V]: `xe_ggtt.c` invalidates GGTT TLBs on `tile->media_gt` as well as the primary GT (l.605/633). `xe_pt.c` (l.2496/2817) issues PPGTT invalidations per GT including media. **Every bind/unbind must also send TLB invalidation to the media GuC**, or VCS reads stale PTEs [I: our kext only talks to one GuC today].

### How much duplication [I]
Roughly 60-70% of the primary-GT GuC path is reused once `rd/wr` take a GT base:

| Piece | Effort |
|---|---|
| GuC reset, PAT, WOPCM, firmware DMA, params, wait for READY | reuse with offset |
| ADS | new class masks/golden LRCs (xcs layout) |
| CT | second H2G/G2H pair plus media doorbell/IRQ |
| SLPC | second instance, can stay minimal |
| HuC | new: DMA + auth action |
| Engine setup | per-VCS/VECS (CCTL, HWSTAM, GFX_MODE, HWS_PGA, WAs) |
| Context ids / doorbells | per-GuC namespace (each GuC has its own `guc_id` space) |
| TLB invalidation | fan-out to both GuCs |

Estimate: **~800-1200 new/changed lines**, mostly parameterising `IntelXe::loadGuc/ctSetup/ctSend/ctDrain/submit` on a `Gt` struct.

## 2. Mesa ANV Vulkan Video on Xe2

**Gating** [V] (`anv_physical_device.c:get_device_extensions`, identical on upstream main):
```c
hw_video_encode_supported = device->info.verx10 <= 125;   // Xe2 = 200 -> no encode
video_encode_enabled = hw_video_encode_supported && ANV_DEBUG(VIDEO_ENCODE);
video_decode_enabled = ANV_DEBUG(VIDEO_DECODE);           // env ANV_DEBUG=video-decode
.KHR_video_decode_h264 = VIDEO_CODEC_H264DEC && video_decode_enabled
.KHR_video_decode_h265 = VIDEO_CODEC_H265DEC && video_decode_enabled && device->has_huc
.KHR_video_decode_av1  = ver >= 12 && VIDEO_CODEC_AV1DEC && video_decode_enabled
.KHR_video_decode_vp9  = VIDEO_CODEC_VP9DEC && video_decode_enabled
.KHR_video_encode_av1  = verx10 == 125 && ...
```
- The video queue family is created only if `v_count > 0 && (ANV_DEBUG(VIDEO_DECODE)||ANV_DEBUG(VIDEO_ENCODE))` (`anv_physical_device.c` ~l.2957). `v_count` counts `INTEL_ENGINE_CLASS_VIDEO` (VCS) only. **ANV never uses VECS.**
- `anv_video.c:anv_GetPhysicalDeviceVideoCapabilitiesKHR`: AV1 Main, with film grain allowed only on `ver >= 20` (so BMG gets it). VP9 profiles 0 (8-bit) and 2 (10-bit). Max coded extent 4096×4096 (l.352).
- **HuC dependence** [V]:
  - H.265 decode asserts `has_huc` and runs the HuC slice-to-long kernel (`genX_cmd_video.c` l.245, `genX(h265_huc_s2l)`).
  - H.264 and AV1 do not check HuC.
  - VP9 emits `HUC_PIPE_MODE_SELECT`/`HUC_STREAM_OBJECT` copies (`genX_huc.h:anv_huc_emit_copy`, called from the VP9 probability-update paths) without checking `has_huc`. Whether those copies run on an unauthenticated HuC is **unknown** [I: treat VP9 as needing HuC].
  - Encode BRC also needs HuC (`anv_video_encode_brc_supported`), but that is moot on Xe2.
- **`has_huc` detection** [V]: `common/xe/intel_gem.c:xe_gem_supports_huc` calls `DRM_XE_DEVICE_QUERY_UC_FW_VERSION` with `uc_type = XE_QUERY_UC_TYPE_HUC`, and treats ioctl success as true. Linux `xe_query.c` returns `-ENODEV` unless the media GT's HuC status is `RUNNING`. Our `xe_core.cpp:1061` returns ENODEV for anything except GUC_SUBMISSION, which is correct until HuC is up.
- **uAPI ANV video needs from the kext** [V/I]:
  - `DRM_XE_DEVICE_QUERY_ENGINES` with `DRM_XE_ENGINE_CLASS_VIDEO_DECODE` (2) instances and **`gt_id = 1`**. Our query hardcodes gt_id 0. ANV copies `gt_id` into `exec_queue_create` instances (`vulkan/xe/anv_queue.c:112`).
  - `DRM_XE_DEVICE_QUERY_GT_LIST` should list the media GT (`DRM_XE_QUERY_GT_TYPE_MEDIA`). Mesa only reads the MAIN entry (`dev/xe/intel_device_info.c:157`), so this is optional but correct.
  - `EXEC_QUEUE_CREATE` on class 2 and gt 1, routed to the media GuC.
  - VM_BIND, EXEC and syncobjs are the same as today.
  - Video BOs are ordinary BOs; nothing PXP/protected unless the app asks for protected content.
- **Meson** [V] (`meson.build`): codec names are `h264dec, h265dec, av1dec, vp9dec` (plus `all`, `all_free`). Our build has `video-codecs=[]`. Use:
  `meson configure build -Dvideo-codecs=h264dec,h265dec,av1dec,vp9dec`. `all` also works; the encode entries are harmless but unused on Xe2. Then run with `ANV_DEBUG=video-decode`, or patch the gate to `true` under `HAVE_XEMAC`.
- **Encode**: not available on Xe2 in ANV at all. Encode would mean porting Intel's media-driver (VA-API iHD/VPL) or writing ANV encode for Xe2 yourself. Neither is a near-term goal.

## 3. macOS integration

### (a) Vulkan Video apps directly. Feasible, the best first target.
- FFmpeg [V]:
  - `libavutil/hwcontext_vulkan.c` on `__APPLE__` dlopens `libvulkan.dylib`, `libvulkan.1.dylib`, then `libMoltenVK.dylib`. It enables `VK_KHR_portability_enumeration` only if present.
  - `configure` needs Vulkan headers ≥ 1.3.277. The VP9 Vulkan hwaccel needs headers ≥ 1.4.317 (`vp9_vulkan_hwaccel_deps="vulkan vulkan_1_4"`).
  - Build: `./configure --enable-vulkan --enable-libshaderc` (shaderc optional, for filters) with Vulkan-Headers on the include path.
  - Run: `VK_DRIVER_FILES=/Library/GPUBundles/nvmtl/intel_icd.json DYLD_LIBRARY_PATH=/Library/GPUBundles/nvmtl ANV_DEBUG=video-decode ffmpeg -init_hw_device vulkan=vk:0 -hwaccel vulkan -hwaccel_output_format vulkan -i in.mkv -f null -`. The loader and ICD JSON already exist for nullmoth (`nvmtl_vk.c:60-113`).
  - ffmpeg's decode path is headless, so it does not depend on WSI [I]. Blockers to check:
    1. ffmpeg's required device features/extensions: timeline semaphores, `synchronization2`, `VK_KHR_video_maintenance1`, plus external-memory/DRM-format-modifier extensions it uses optionally.
    2. Our ANV build's exposed extension set under xemac, e.g. `ANV_FD_SHARING=false`.
- mpv/IINA [I]: ANV here has only `VK_EXT_headless_surface` (`anv_instance.c:77`, `platforms=[]`). There is no `VK_EXT_metal_surface`, so `--gpu-api=vulkan` cannot present on the ANV device. `--hwdec=vulkan-copy` (decode on ANV, copy back to RAM, present via the normal Metal/GL VO) should work once ffmpeg works. Zero-copy would need a Metal WSI in Mesa (Mesa has a Metal WSI used by KosmicKrisp) or IOSurface interop with nullmoth.

### (b) VideoToolbox
- **Private registration, proven in our own tree** [V] (`nullmoth/plugin/NVMTLDevice.m`):
  - nullmoth calls `VTRegisterVideoDecoderWithInfo('avc1'|'hvc1', {CMClassImplementationID, VTRating=1000, VTIsHardwareAccelerated=YES}, factory)`. It does the same for encoders via `VTRegisterVideoEncoderWithInfo`.
  - Its comments record how this reaches Apple apps. Safari's WebKit GPU process, QuickTime Player and Preview hand decoding to **`VTDecoderXPCService`**. The Metal plugin bundle is mapped into that process, so a constructor registers the decoders there (`nvmtl_nvdec_in_decode_service`). In-process registration inside sandboxed Apple apps fails, which is issue #349 in their notes. Chromium decodes in its own GPU process.
  - The rating mechanism suggests VT picks the highest-rated registered decoder for a codec, so a registered decoder **can** beat Apple's. That is inferred from nullmoth's design and its "rating 1100 beats our 1000" comment; I did not verify it in Apple binaries.
  - The factory implements the VTVideoDecoder plugin ABI (the `VTVideoDecoderClass` vtable: StartSession, DecodeFrame, etc.). nullmoth's `libnvdec_*.dylib` is a working reference for that ABI.
- **Public routes** [V web/I]:
  - `VTRegisterSupplementalVideoDecoderIfAvailable(codec)` only activates **Apple's** supplemental decoders (VP9/AV1). It takes no third-party code.
  - **MediaExtension** `MEVideoDecoderExtension` (macOS 15) is a sandboxed ExtensionKit decoder for formats the system *does not natively support*, and apps must opt in (`VTRegisterProfessionalVideoWorkflowVideoDecoders`). Final Cut Pro, Compressor and similar apps do; Safari does not. It cannot override H.264/HEVC.
  - `/System/Library/Video/Plug-Ins/*.videodecoder` bundles are SIP-protected system paths and should not be relied on.
  - The AppleGVA + `AppleIntel*VADriver` route is Apple's own Intel media stack. It is hardwired to Apple's Intel kexts and command formats (TGL VA for Gen12), not BMG. Reusing it would mean emulating AppleIntel's VA user-client ABI. That is not realistic.
- **Context on this machine** [I]: the UHD 770 with AppleIntelTGL VA already gives VideoToolbox hardware H.264/HEVC. A B580 VT decoder for those codecs is therefore mostly a nicety, unless the iGPU path goes away. The real gap is **AV1**. Apple's VT exposes AV1 hardware decode only on M3+. Safari AV1 on Intel Macs relies on the hardware query (`VTIsHardwareDecodeSupported`) and `av01` decoder availability. A registered `av01` decoder with `VTIsHardwareAccelerated=YES`, rating 1000, living in VTDecoderXPCService is the most interesting target, but also the least certain: whether WebKit's capability check sees registered decoders is **unverified**.
- **Sandbox** [I]: the kext's user client is `IOAccelIntelXeClient` (prefix "IOAccel", `IntelXeClient.cpp:14-17`) so that WindowServer's sandbox can open it. VTDecoderXPCService's profile very likely allows IOAccel user clients too, since Metal works there, but confirm before building a VT decoder on it.

## 4. Staged plan

| # | Stage | Effort | Deliverable |
|---|---|---|---|
| 0 | Read-only probe: media GMD_ID (already printed), 0x389140 fuses, media forcewake ack 0x380dfc, media GuC status 0x38c000, HUC_KERNEL_LOAD_INFO 0x38c1dc | 0.5 day | Exact VCS/VECS list, confirms GT1 alive |
| 1 | Refactor kext MMIO/GuC/CT code to take a `Gt` (base 0 / 0x380000); media forcewake; media GuC load with VIDEO/VECS-only ADS, golden xcs LRC, second CT, media G2H interrupt (OTHER inst 16, ENGINE0 bit), TLB invalidation to both GuCs | 1-2 weeks | `MI_STORE_DATA_IMM` on VCS0 via media GuC (like the step=6 BCS test) |
| 2 | xe uAPI: engines query with class 2/3 and gt_id 1, GT_LIST media entry, exec queues routed by gt_id; media WAs above; power gating off | 2-4 days | `vulkaninfo` shows a video queue family (`ANV_DEBUG=video-decode`) |
| 3 | Mesa `-Dvideo-codecs=h264dec,h265dec,av1dec,vp9dec`; build FFmpeg with `--enable-vulkan` against nullmoth's loader/ICD | 2-3 days | **First visible win:** `ffmpeg -hwaccel vulkan` decodes **AV1 and H.264** on the B580 (benchmark vs software; 4K/8K AV1 is the showcase) |
| 4 | HuC: WOPCM with HuC region + `HUC_LOADING_AGENT_GUC`, DMA `bmg_huc.bin` with HUC_UKERNEL before media GuC, `AUTHENTICATE_HUC` H2G, poll 0x38c1dc, report via `UC_FW_VERSION(HUC)` | 3-5 days | HEVC (and safely VP9) decode in ffmpeg |
| 5 | mpv/IINA with `--hwdec=vulkan-copy` (no Mesa changes) | 1-2 days | Smooth AV1/HEVC playback in a player |
| 6 | VideoToolbox decoder dylib (VTVideoDecoder ABI, internally Vulkan Video on ANV, output IOSurface-backed CVPixelBuffers), registered from the nullmoth plugin for `av01` (and optionally `hvc1`/`avc1`), including in VTDecoderXPCService | 3-6 weeks | AV1 in Safari/QuickTime, if WebKit accepts it |
| 7 | Encode | months | Not via ANV on Xe2; out of scope |

**Biggest risks and unknowns**
1. **Media GuC bring-up.** It is a second firmware instance sharing the GuC interrupt registers and TLB-invalidation duties. Getting the mask RMW or the TLB fan-out wrong gives silent stale-PTE hangs. This hackintosh has a GPU-hang history, so test with runtime kmutil-loaded kexts.
2. **HuC authentication via GuC on BMG.** It is verified in Linux, but only working hardware will show it. Needs `bmg_huc.bin` from linux-firmware, and the file may carry GSC/CPD headers (`xe_uc_fw.c:parse_cpd_header` handles both layouts).
3. **VP9 HuC-pipe copies** without authenticated HuC are untested.
4. **ffmpeg on our ANV:** required features under xemac (no fd sharing) are unverified, and ffmpeg's Vulkan path on macOS gets little testing upstream.
5. **VideoToolbox:** private API stability across macOS updates. Whether Safari's AV1 capability check counts a registered `av01` decoder, and whether VTDecoderXPCService's sandbox allows `IOAccelIntelXeClient`, are both unverified.
6. **iGPU overlap:** for H.264/HEVC on this machine, the B580 path competes with a working Apple iGPU path, so the user-visible value is concentrated in AV1.
