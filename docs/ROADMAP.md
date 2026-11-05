# Roadmap

The order is roughly the intended one. Every item should follow the Linux xe/i915 and Mesa way of doing it, not a macOS-only shortcut (see the README's philosophy section).

## Near term (Arc B580)

### VideoToolbox
- **Done (2026-10-29):** AV1 decoder and HEVC/H.264/AV1 encoders, registered in-process by the plugin in every Metal process (VTDecoderXPCService included); FFmpeg shared.
- **Done (2026-10-30):** H.264 and HEVC decoders; encoder quality work after media-driver (Mesa `0040`–`0045`); FFmpeg 9.0.2 with the patches in `videotoolbox/ffmpeg/`.
- **Done (2026-10-30):** AV1 encode with one B frame, the HuC BRC GOP model and two PAK passes (Mesa `0046`/`0047`, codecs-vqa5). 1080p60 VBR 3/6/12 Mbit/s, BD-rate against SVT-AV1 on Netflix Aerial: PSNR-Y +161.8% → +135.7%, VMAF +89.8% → +68.6%. Known limitation: the rate overshoots by 16–18% at the lowest rate (3 Mbit/s).
- **Next:** AV1 is still behind SVT-AV1 (hierarchical GOPs, CDEF under rate control, the overshoot).
- **Next:** GPU copies into the session's IOSurfaces instead of CPU staging copies; QuickTime/Safari playback checks; drive Vulkan Video directly where libavcodec adds nothing.
- **Upstream:** H.264 and AV1 encode for Xe2 in ANV (`mesa/patches/0010`, `0012`, `0015`).

### CPU-visible VRAM (BAR window)
- **Done:** page-table reserve, spills to system memory, map-time moves to system memory, working CPU unmaps, `debug.intelxe.vram`; plugin descriptor pools that grow and a dense set layout (window per drawing process 100 -> 30 MB).
- **Open:** a BO the CPU has mapped never leaves the window (an IOKit mapping of a physical range cannot be repointed, unlike Linux's faulting mmaps), so placement is first come, first served. Options: fewer persistent mappings in Mesa's internal pools, or a revocable mapping scheme. macOS cannot use a BAR larger than 1 GB (OpenCore `ResizeAppleGpuBars` documentation).
- **Upstream:** the ANV mutable-descriptor-list indexing fix (`mesa/patches/0013`).

### VRAM-shared IOSurfaces
- **Done:** on at boot with `intelxe_surfvram=2` (applications and WindowServer), as the 0.1.x install guide sets it; frames stay in VRAM from render to scan-out instead of crossing PCIe twice per frame (90 % of a game frame's GPU time). The kernel's own default is still 0 (off) without the boot-arg.
- Open: make it the kernel's default once more machines have run it.

### Descriptor model
- Stage 1 (front end without per-draw atomics or retain/release, address table, bind cache): done. Stage 2, the descriptor-buffer model, is in the plugin behind `NVMTL_DESC_MODEL=buffer` and off by default until it has been soaked (`docs/design/DESCRIPTOR-MODEL.md`).
- Pools: done (see the BAR window). A full pool set now waits for in-flight work and then fails the command buffer with a Metal error, never silently.
- WindowServer and app frames still cost a lot of CPU time in descriptor and submit handling. Minecraft profiling showed descriptor-set allocation as the top cost before the recycling fix.
- The goal is a descriptor model that maps Metal's argument buffers and bindless resources onto ANV's descriptor heaps (`VK_EXT_descriptor_buffer` style) instead of per-draw descriptor sets.

### Variable refresh
- **Done (2026-10-29):** Adaptive-Sync with an LFC pacer (monitor 48–180 Hz), and the "Variable" entry in System Settings.
- Next: tests with games and video playback.

### GPU resets
- **Done (2026-10-30):** register save/restore lists for engine resets, queue replacement on the same VM in Mesa and the plugin; WindowServer survives a GT reset.
- The full Vulkan CTS run of 2026-11-04 (3.15 M cases) finished without a hang, a GT reset or a lost device; the three cases that used to hang (a timeline blit, an R8G8B8 sRGB multi-layer clear, a transform-feedback teardown) pass or fail cleanly.
- Open: deliberate hang tests on the released kernel (the last ones ran on rb5/rb6b).

### Browsers
- **Done (2026-10-30):** Chrome/Electron in their GPU sandbox; Safari WebGL through the optional system-volume plugin copy.
- Open: the system-volume install breaks the sealed snapshot (as OpenCore Legacy Patcher's root patches do); a macOS update removes it (`ssv-install.sh --check`).

### Integrated GPU
- Out of scope for this stack: the test machine runs with the CPU's integrated GPU off. A headless iGPU next to the B580
  (Quick Sync through VideoToolbox) needs a separate iGPU driver and is not tested with this release.

### Remaining items from the workaround audit (2026-10-29)
- Boot guard: since IntelXeFB v10c it needs WindowServer's own framebuffer connection and sustained accelerated frames; check it over a few boots, including a deliberately failing one.
- Video was behind a debug gate; it is now on by default with the media GT up. Remove the ffmpeg vkshim.
- Remove the AMFI boot-args: sign the plugin properly and use entitlements.
- System sleep: works on the released kernel (rb7u + IntelXeFB v10m, macOS 26.7.1). Open: in the tests of 2026-10-30 the machine woke by itself about 7 s after going to sleep (USB wake source, USBW); not re-checked on the released kernel.
- Display hot-plug: interrupt-driven, instead of polling.
- Second display pipe (pipe B, DBUF/MBUS split, watermarks). The test setup has only one monitor.

## Other Xe2 (Battlemage) cards

The kext is organized around the graphics IP version (Xe2 / graphics 20.01, media 13.01, display 14.01), not the board.

| Card | Device | What is expected to differ |
|---|---|---|
| Arc B570 | BMG-G21, fewer Xe-cores | device ID; fuse-driven topology (already read from fuses) |
| Arc Pro B50 | BMG-G21 workstation | device ID; VRAM size and BAR layout |
| Arc Pro B60 | BMG-G21 workstation, 24 GB | device ID; larger VRAM (allocator and BAR window are already sized from the hardware) |
| Arc Pro B70 | larger Battlemage configuration | device ID, topology; possibly display/PHY tables |

Each needs:
- the `IOPCIMatch` IDs;
- a check of the per-SKU workaround and tuning tables against Linux xe (`xe_wa.c`, `xe_tuning.c`);
- a check of the firmware it uses (BMG GuC/HuC are shared within the family);
- a hardware test.

## Later generations

These need per-generation modules, the way Linux xe separates them, rather than conditionals spread through one file.

| Generation | Examples | Main new work |
|---|---|---|
| Lunar Lake (Xe2-LPG, integrated) | Core Ultra 200V | No VRAM: an integrated memory model with system memory and the stolen region. Different display (Xe2_LPD). GSC-loaded HuC. Shared LLC. |
| Alchemist (Xe-HPG, DG2) | Arc A380/A750/A770 | Graphics 12.55: different LRC layouts, workarounds, MOCS/PAT, GuC ABI subset. Display 13. GSC for HuC and firmware loading. |
| Panther Lake (Xe3) | Core Ultra 300 | Graphics 30.x: new LRC/workaround tables, new display IP. Integrated memory model as for Lunar Lake. |
