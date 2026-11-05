# Changes to nullmoth for the Arc B580

This directory is a copy of the parts of [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver)
that the IntelXe stack uses, with our modifications applied.

- **Upstream base:** `6e375469bd02f5421a2a3d7c408507d5099e2c38` ("Changelog 2.6.2", 2026-10-26), branch `main`.
- **Merged from upstream 2.6.6 (2026-11-03, in the released plugin):** of the 91 upstream commits between 2.6.2
  (`29432bb` on today's `main`; upstream rewrote its history, so `6e37546` is not an ancestor of `main`) and 2.6.6 that
  touch the plugin and the translator, the 41 general fixes and 4 that can be switched off were taken as 45 patches;
  NVIDIA-specific changes were left out. The released plugin is that merge plus our ray-tracing and uniform-buffer work.
  2.7.1 is reviewed but not merged yet.
- **Our work:** one commit on a local branch `b580` (`428ca50`, "NMXAccel for the Arc B580: class-name header, no NVIDIA headers, B580-only personality"), plus working-tree changes made 2026-10-28/30. Both are included here; the repository history records each installed state.
- **Recorded diff:** `b580-changes-vs-6e37546.diff` is the diff of these directories against the base commit as it
  stood on 2026-10-30, with the names of that time (the stack was renamed from B580 to IntelXe on 2026-11-05). It is a
  record and is not updated: later changes, the rename included, are in the files here and in the repository history.

## Why a copy and not a subtree

The upstream repository is the whole NVIDIA product: the NVRM kernel module built against NVIDIA's open GPU kernel modules, NVRMFB, NMDRM, NMHDA, the NVK patches, GSP firmware handling, the installer and tools. Only the Metal plugin, the shader translator and two kexts are used for the B580.

A `git subtree` would bring the full upstream history and all of those components into this repository. Our own history on top of it would still be short: most of our changes were made in a working tree, not as upstream-style commits.

A copy of the four components gives us:
- a self-contained build;
- the pinned base commit;
- this file and the diff, which record our changes exactly.

## What is included

| Path | Upstream path | Licence |
|---|---|---|
| `plugin/` | `plugin/` (NVMTLDriver.bundle, the Metal driver plugin) | PolyForm Noncommercial 1.0.0 |
| `translator/` | `translator/` (AIR → SPIR-V, based on metal2vulkan) | LGPL-3.0-or-later (`translator/LICENSE`, `translator/COPYING`) |
| `kexts/NVRM/accel/` | same (built with `-DNMX_ACCEL` as NMXAccel.kext) | PolyForm Noncommercial 1.0.0 |
| `kexts/NVRM/nvrm_off.h`, `nvrm_gpuva_abi.h`, `nvrm_vram_abi.h`, `nvrm_surfshare_abi.h` | same (headers NMXAccel includes, unmodified) | PolyForm Noncommercial 1.0.0 |
| `kexts/NVRMAGDC/` | same (built with `-DNMX_AGDC` as NMXAGDC.kext) | PolyForm Noncommercial 1.0.0 |
| `LICENSE`, `NOTICE` | upstream root, unmodified | — |
| `build/build-intelxe.sh` | ours (adapted from upstream `build/build_plugin_release.sh` / `build_xlate_release.sh` / `accel_build.sh`) | MIT |

Required Notice: Copyright (c) 2026 NullMoth Systems (https://nullmothsystems.com)

Note: `kexts/NVRM/accel/iofam/`, `kexts/NVRM/accel/re/` and `kexts/NVRMAGDC/AppleGraphicsDeviceControl_re.h` are upstream's own interface declarations for Apple's IOAcceleratorFamily2 and AppleGraphicsDeviceControl classes. They are included unmodified, except for two one-line changes listed below, because the kexts do not build without them.

## Modifications by component

### NMXAccel (`kexts/NVRM/accel/nvrm-accel.cpp`, `nmx_accel_names.h`, `nvaccel_stubs.h`, `Info-NMX-IntelXe.plist`, `iofam/IOAccelSurface.h`, `iofam/IOAccelLegacySurface.h`)

- **`nmx_accel_names.h` (new):** the OSMetaClass names of the released NMXAccel.kext 2.1.0. Upstream's `-DNMX_ACCEL` build includes this header but does not ship it.
  - The NMX build no longer needs NVIDIA's `nvkms-kapi.h`.
  - It does not read NVIDIA's temperature register from another vendor's BAR0.
- **`Info-NMX-IntelXe.plist` (new):** matches only `8086:e20b`, in the `IOAccelerator` match category.
- **Display head:** the framebuffer of IntelXeFB (`IntelXeFramebuffer`) is watched as head 0.
  - `nvScanoutInfo` and VRAM allocation calls are answered through IntelXeFB.
  - Placeholder GPU VAs; commit/release are no-ops for NMX.
- **Display pipe:** a full `IOAccelDisplayPipeCapabilities` is published, so IOPresentment builds a display pipe. Multi-client VBL.
- **`NVSurface::submitCopyForward`:** implemented with CPU rect copies. The family default returned Unsupported, and WindowServer never swapped.
- **Present path:**
  - **Async swap:** user client `IOAccelNMXPresent` ('NMXP') carries the plugin's surface-ready marks. `performTransaction` runs on a thread call: wait for the mark, then copy or flip, then signal.
  - **Real flips:** the plane scans the composite's VRAM buffer, pinned through IntelXe.kext and mapped into GGTT slots by IntelXeFB. Completion is detected when `PLANE_SURFLIVE` matches.
  - **Hardware gamma:** the transaction's post-gamma table goes to the pipe's LUT through IntelXeFB `nmxPipeGamma`.
- **xe user client through NMXAccel:** `newUserClient` type 'B580' hands out IntelXe.kext's `IOAccelIntelXeClient`. Sandboxed system-graphics processes may open only IOAccelerator clients, so this gives them Metal.
- **Adaptive-Sync:** the frame-length range of an IOPresentment transaction (a "Variable" refresh mode published by IntelXeFB) is passed on to IntelXeFB.
- **Boot-time arming:** `boot1`. The display pipe and transactions are armed in the kernel when IntelXeFB matches at boot, with an NVRAM guard.
- **Sysctls:**
  - `debug.nmxaccelfb`, `debug.nmxaccel_iop*`, `debug.nmxaccel_async`, `debug.nmxaccel_flip`;
  - counters `debug.nmxaccel_scanout_copies`, `debug.nmxaccel_copy_forwards`, `debug.nmxaccel_flips`, `debug.nmxaccel_flip_late`, `debug.nmxaccel_flip_refused`.
- **Boot ordering (boot1d):** registered at start again, `debug.nmxaccelfb` reads 1 while the boot-time arm is pending; the arm waits for IntelXeFB and the accelerator to go quiet; registration and mode-change delivery run inside IOGraphics' system and controller gates through IntelXeFB's `intelxefbRunGated` (run bare they deadlocked against AppleGPUWrangler at boot).
- **VRAM-shared IOSurfaces (sv7):** the registry of IOSurfaces adopted into B580 VRAM (kernel ABI `kernel/IntelXe/uapi/intelxe_surfvram_kabi.h`, shared with IntelXe.kext; the build adds that directory to the include path), page-off/page-in through B580's copy engine, phase 4 (WindowServer composites whose readback the plugin skipped). Off until `debug.intelxe.surfvram` is set.
- **Metal plugin location (nmx-ssv2):** `MetalPluginName` names `/System/Library/Extensions/NVMTLDriver.bundle` when the optional system-volume copy is installed (WebKit's GPU process may load plugins only from there), otherwise the `/Library` copy, installed as `NVMTLDriverLib.bundle` so that it cannot shadow the system one. Boot-arg `nmxplugin=lib` or `/Library/GPUBundles/NVMTLDriver.use-library` force the `/Library` copy. Published as `NMXMetalPluginFrom`.
- **`iofam/IOAccelSurface.h`, `iofam/IOAccelLegacySurface.h`:** one line each. `submitCopyForward` and `set_shape_backing_length_ext` return `IOReturn` (not `void`), which matches the family and lets the override report a result.

### NMXAGDC (`kexts/NVRMAGDC/nvrm-agdc.cpp`, `nvrm-agdc-k5.h`, `Info-NMX-IntelXe.plist`)

- **Boot ordering:** waits for IntelXeFB's registration to finish before listing it (boot1c hung arming while IntelXeFB was still being published).

- **`Info-NMX-IntelXe.plist` (new):** loads the AGDC service for the B580 only.
- **Command 0x980:** lists IntelXeFB, so WindowServer builds a display pipe for it.
- **Commands 0x921 (link config) and 0x711:** answered with nullmoth's `NVRMTiming` (K5) for IntelXeFB.
- **0x711 gamma capability:** a 3-channel, 10-bit, 1024-entry pipe gamma, so CoreDisplay skips its own per-frame gamma pass. Switch: `debug.nmxagdc_gamma`.

### Metal plugin (`plugin/`)

- **Vendor `0x8086` path:**
  - loads our ANV (`/Library/GPUBundles/nvmtl/`);
  - short device name "Intel Arc B580 Graphics";
  - the allow-list gains `!Name` (only while the display pipe is armed) and `!*`.
- **WindowServer:**
  - framebuffer fetch on by default for non-NVIDIA devices (`NVMTL_FBFETCH_WS=0` disables);
  - background translation off in WindowServer.
- **Buffer-backed textures (`nvmtl_vk.c`):** `image_create_buffer_alias` now checks only the import's memory type (`nvk_buffer.mtype1`), not every type. With ANV on Xe2, every buffer texture had been refused and turned into a one-time copy, which left stale text fields.
- **Mipmaps:** `nvmtl_mip_autofill` generates mips on the GPU for Core Animation's level-0-only uploads.
- **Samplers:** a stale constexpr sampler was left in the app's slot 0 and caused Dock/text pixelation. The plugin now rebinds the app sampler.
- **Screen capture:** synchronized exactly through a page-offset wait. This replaced the "first 16 flushes" heuristic.
- **Implicit IOSurface synchronization:** uses IntelXe.kext's surface fences (`uapi/intelxe_drm.h`) instead of CPU waits.
- **Import slots:** WindowServer now reaps implicit-sync import slots. Before this, the slots filled up and it fell back to unsynchronized CPU copies (the Minecraft glitches).
- **Surface-out:** copies go straight into imported IOSurface pages, cached imports, and folded surface-out. This is the first part of the async present path.
- **Memory:**
  - every Managed no-copy buffer gets a VRAM mirror;
  - descriptor recycling;
  - big-buffer parking;
  - an autorelease leak fixed;
  - scan-out buffers use an uncompressed memory type. ANV picks compressed PAT entries for device-local memory, and the linear display plane cannot read CCS.
- **OpenGL (Apple's GL over Metal):** Intel GL profile provoking-vertex bit.
- **Diagnostics:** `NVMTL_HITCH_MS`, `NVMTL_KTIME`, `NVMTL_PSTAT`, `NVMTL_XLATE_FAIL_DUMP`.
- **VideoToolbox codecs (fix28):** registers the B580 AV1 decoder and HEVC/H.264 encoder plug-ins (`libintelxeav1dec.dylib`, `libintelxevenc.dylib` in `/Library/GPUBundles/nvmtl`, see `videotoolbox/`) in every process that loads the plugin; `NVMTL_NO_INTELXEDEC=1` / `NVMTL_NO_INTELXEVENC=1` keep a process out.
- **GPUTIME (fix29b):** per-pass GPU time profiler, on while `/tmp/nvmtl-gputime` exists.
- **Staged IOSurface host copies, SURFCENSUS (fix29c).**
- **Descriptor pools (fix30-32):** pools grow from 256 sets instead of starting at 4096 (77 MB of the CPU-visible BAR window per process); a set layout with one binding per binding number, so ANV's reading of the mutable-type lists by binding number (see `mesa/patches/0013`) and the spec's by index agree (a pool held a fifth of its sets before); when no set can be had even after waiting for in-flight work to return some, the command buffer ends with `MTLCommandBufferErrorOutOfMemory` instead of being committed without the draws (`NVMTL_SUBMIT_PARTIAL=1`: the old behaviour; `NVMTL_DESC_POOLS_MAX`: a lower ceiling for tests).
- **Descriptor model (stages 1b-1d, 2):** no per-draw retain/release and no atomics in the draw path, an address-table shadow with trimming, a bind cache; the descriptor-buffer model (`nvmtl_dbuf.c`) behind `NVMTL_DESC_MODEL=buffer`, off by default. Design: `docs/design/DESCRIPTOR-MODEL.md`.
- **CAMetalLayer drawables (sv10)** count as writers of their IOSurface; **Tile4 IOSurface import** (size `pitch * align32(height)`).
- **VideoToolbox decoders (intelxedec v2):** H.264 and HEVC next to AV1, registered only when no other accelerator offers them; the AV1 encoder registration (sv9).
- **Sandboxed processes:** when `debug.nmxaccelfb` is sandbox-denied, the arm state comes from NMXAccel's `NMXAutoArm` property (Chrome's GPU process), and where WebKit hides that too, from the `IOAccelDisplayPipeCapabilities` (sc6arm). Where a sandbox refuses to open `/dev/null` (WebKit's GPU process), the descriptor xemac and the surface imports need is made by `dup` of a standard descriptor (sc6dn): Safari's WebGL runs on the B580.
- **Bundle companions (dec4):** Mesa and the translator are also found inside the plugin's own bundle (`Contents/Frameworks/nvmtl`), the layout of the system-volume copy.
- **GPU reset recovery (recover1):** a banned exec queue is replaced on the same VM through Mesa's `nvmtl_anv_device_recover_v1` (`mesa/patches/0050`); at most 3 per minute and 16 per process.
- **Function constants (speccst6):** variants are specializations of one translated module (`nvmtl_spec_fc.h`); only the constants that shape the module are baked in.
- **VRAM-shared IOSurfaces (sv2-sv8):** IOSurfaces in shared B580 VRAM through Mesa 0014 and NMXAccel's registry, with implicit sync of every access, instead of per-process VRAM copies synchronised with the system pages. Off until `debug.intelxe.surfvram` is 1 (apps) or 2-3 (also WindowServer).

### Translator (`translator/`)

- **Structurizer:**
  - a loop's merge block belongs to the construct around the loop. A valid plan for clang-rotated bottom-tested loops is no longer rejected (Geekbench OpenCL `trace_bvh_shadow`: 130 ms → 1 ms per dispatch);
  - lifetime-only blocks count as bare returns;
  - plan-cache comparisons use `Arc` identity or value instead of Debug strings.
- **Rewrites:**
  - OpenCL `native_*` math as AIR `fast_*`;
  - integer atomics on a whole `__local` aggregate get an access chain to the scalar (`AtomicSMax`);
  - one-element vector views (`uchar4` over u32 words) are bitcast.
- **`wrapper/src/buffer_addresses.rs`:** descriptor-kept buffers at offsets that are not a multiple of the storage-buffer alignment are indexed from the rounded-down offset, plus the remainder.
- **Function constants as specialization constants (`wrapper/src/spec_fc.rs`, `meta/`):** `nvmtl_fc_structural` lists the constants the module's shape depends on; `nvmtl_translate_fc_spec2` bakes those, translates with the others unknown and turns each remaining one into a SPIR-V specialization constant. Every other entry point gives byte-identical output.
- **`translator/Cargo.lock`:** regenerated by `cargo build` of the wrapper on this machine. It is smaller than upstream's because it resolves only the wrapper's dependency graph.
