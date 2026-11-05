# B580 → VideoToolbox AV1 decode: research and plan

> Design note with its date: it records the plan and the state of that day, not the current status. The current
> state is in the README and `docs/devices/b580.md`.

**[V]** = I read it in source, a binary or disassembly. **[I]** = inference.

Sources:
- nullmoth `plugin/NVMTLDevice.m`, and `libnvdec_hevc.dylib` from the nullmoth release v2.6.3 (`scratchpad/nmrel/`).
- VideoToolbox and MediaToolbox from the hackintosh's dyld cache (`dscout/`, otool + `dscvm.py`; full listing in `scratchpad/vt.s`).
- WebKit main (`scratchpad/wk/`).
- The bundles and sandbox profiles of the build Mac (macOS 27). Section 2 says where these may differ on macOS 15.
- IntelXe kext and Mesa sources.

## TL;DR

1. **The skeleton can be reused. The NVIDIA-specific parts are the engine access and the CPU detile.** The `libnvdec_*` ABI is plain VTVideoDecoder:
   - `CMDerivedObjectCreate`, `kVT` → `kBase`/`kDec` vtables;
   - `VTDecoderSessionSetPixelBufferAttributes` / `GetPixelBufferPool` / `EmitDecodedFrame`. [V]
   - The engine is reached through `IOServiceMatching("NVAccel")`. [V]
2. **Safari's check is purely registry-based.** `VTIsHardwareDecodeSupported('av01')` only asks whether a decoder entry exists in the calling process with `VTIsHardwareAccelerated=true`; it never runs the factory. [V] WebKit runs this check **in its own GPU process** and caches the answer. [V WebKit main]
3. **Best route: a decoder bundle in `/Library/Video/Plug-Ins`.** It is not tied to when the Metal plugin loads, and the registry entry becomes visible in every process. VT adds this directory to its search path [V]. Its Info.plist schema is the same as `AV1DecoderSW.bundle`'s [V]. Fallback: nullmoth-style `VTRegisterVideoDecoderWithInfo`.
4. **The biggest blocker is the sandbox IOKit rule.** The VTDecoderXPCService and WebKit GPU sandboxes only allow `iokit-connection "IOAccelerator"`. `B580 : IOService` is not an IOAccelerator, so `IOAccelIntelXeClient` would be refused there [V profile + kext source; I for the outcome]. Fix: hand the xe client out through NMXAccel (`IOGraphicsAccelerator2`), the way nullmoth's `NVAccel::newUserClient` hands out NVRM clients.
5. **H.264/HEVC are not affected.** We register only `av01`, so nothing competes with Apple's GVA decoders. [V for the mechanism]
6. **First step: a stub decoder that outputs grey frames (1–2 days).** It settles whether Safari/YouTube will pick AV1 before any Vulkan work.

## 1. What nullmoth's NVDEC route provides, and what is NVIDIA-specific

### Registration [V, NVMTLDevice.m]
- **Call:** `VTRegisterVideoDecoderWithInfo('avc1'|'hvc1', {CMClassImplementationID, VTRating=1000, VTIsHardwareAccelerated=YES}, factory)`. The factory is `NVDec*_CreateInstance`, from a library loaded with `dlopen` next to the bundle.
- **Three entry points:**
  1. `initWithAcceleratorPort:` for vendor 0x10de, only **after** the allow-list check;
  2. a constructor that runs only in `VTDecoderXPCService`. It runs `dispatch_async`, finds the GPU with an IOPCIDevice scan (10de), and does not need a Metal device;
  3. a skip in Apple sandboxed processes (`sandbox_check` + `com.apple.*` bundle ID). Those delegate to VTDecoderXPCService (PR #349, tested by a contributor on 15.8.1/RTX 4080).
- **Other gates:** never in WindowServer; `NVMTL_NO_NVDEC`.

### Decoder object [V, symbols and vtables of `libnvdec_hevc.dylib`]
- **Factory:** `OSStatus F(FourCharCode codec, CFAllocatorRef, VTVideoDecoderRef *out)` → `CMDerivedObjectCreate(alloc, &kVT, VTVideoDecoderGetClassID(), &obj)`, derived storage 0xb8 bytes.
- **`kBase`:** Invalidate, Finalize, CopyDebugDescription, CopyProperty.
- **`kDec`, in slot order:**
  1. StartSession
  2. DecodeFrame
  3. CopySupportedPropertyDictionary (`UsingHardwareAcceleratedVideoDecoder`, read-only)
  4. SetProperties
  5. CopySerializableProperties
  6. CanAcceptFormatDescription (`CMFormatDescriptionEqual`)
  7. FinishDelayedFrames
- **StartSession:**
  - reads the parameter sets from the format description;
  - opens the engine;
  - passes width/height/pixel format plus `kCVPixelBufferIOSurfacePropertiesKey` to `VTDecoderSessionSetPixelBufferAttributes`.
- **DecodeFrame:**
  - parses its own NALs (`ue/se/parse_st_rps`);
  - submits to NVDEC;
  - takes a buffer from `CVPixelBufferPoolCreatePixelBuffer`;
  - **detiles on the CPU** into `CVPixelBufferLockBaseAddress` + `GetBaseAddressOfPlane` (`dispatch_apply`);
  - calls `VTDecoderSessionEmitDecodedFrame`.

So the NVDEC route is **not zero-copy**.

**NVIDIA-specific parts:** NVRM ioctls (`nvrm_xnu_*`, `IOServiceMatching("NVAccel")`), the NVDEC class/picture setup, and the Blackwell/classic detile. **Reusable as-is:** the registration code, the vtable skeleton, pixel-buffer pool management, and the error, verbose and statistics plumbing. The Vulkan Video version is the same skeleton with a different engine back end.

### Per-frame work with Vulkan Video [I, design]

**StartSession:**
- Take `av1C` from `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms` (FFmpeg's VT hwaccel also writes it there [V, FFmpeg master `videotoolbox.c`]). Its configOBUs give `StdVideoAV1SequenceHeader`.
- Create `VkVideoSessionKHR` (AV1 Main, 8 or 10 bit, film grain), session parameters, and 8+1 DPB images in VRAM.
- ANV decode output supports **only OPTIMAL or DRM-modifier tiling**, not linear [V `anv_video.c:683`]. Decoding straight into a linear IOSurface is therefore impossible.
- Pixel buffer: NV12 `420v` for 8-bit, P010 `x420` for 10-bit, IOSurface-backed.

**DecodeFrame** (one MP4 sample = one temporal unit, exactly one shown frame):
- parse the OBUs (seq/frame header, tile groups);
- fill `StdVideoDecodeAV1PictureInfo` and tile offsets/sizes;
- set `referenceNameSlotIndices[7]` and the `StdVideoDecodeAV1ReferenceInfo` of each slot;
- keep the reference state (order hints, loop-filter deltas, segmentation, global motion);
- memcpy the bitstream into a host-visible buffer (KBs only);
- record `vkCmdBeginVideoCoding`/`vkCmdDecodeVideoKHR`/`End` on the VCS queue;
- `show_existing_frame` means no decode, only an output copy from the DPB;
- with film grain, use a separate output image (DPB_AND_OUTPUT_DISTINCT).

**Output** (from cheapest to most expensive):
- **(a) Zero CPU copy:** import the IOSurface allocation with `VK_EXT_external_memory_host` (`nvmtl_vk_buffer_import_host`, the same mechanism as the stage-1 surface-in/out path [V nvmtl_vk.c:1408]). Then a per-plane `vkCmdCopyImageToBuffer` (offset = plane offset, rowLength = bytesPerRow/bpp) moves the frame over PCIe. That is 3 MB per 1080p frame and 12 MB per 4K frame. Keep the import cached per pool IOSurface (as `nvmtl_surfimp_get` does). Risks:
  - The GPU must **write** to userptr pages; the B580 notes mention "userptr RO".
  - The video queue probably has no TRANSFER bit, so the copy goes to the graphics queue: timeline semaphore + queue-family ownership transfer, or CONCURRENT images [I].
- **(b) Fallback:** copy into host-visible staging, then memcpy into the pool buffer. About 2–3 ms at 4K, still better than NVDEC's CPU detile.

**Emit:** fence or completion thread, then `VTDecoderSessionEmitDecodedFrame(session, token, noErr, flags, pb)`. Emission order is TU order, which is also display order.

### AV1 parser options

| Option | License | Fit |
|---|---|---|
| **FFmpeg libavcodec** (`cbs_av1` + `av1dec` + `vulkan_av1` hwaccel) | LGPL-2.1+ (fine with dynamic linking) | **Already proven on this stack** (46× realtime). Parser, DPB, Std structs and submission all come with it. `AVVulkanDeviceContext.get_proc_addr` can bypass the loader and plug in ANV's `vk_icdGetInstanceProcAddr` [I]. The native `av1` decoder is hwaccel-only, so it falls back to nothing. **Fastest prototype.** |
| **Khronos Vulkan-Video-Samples `NvVideoParser`** (`VulkanAV1Decoder.cpp`, 95 KB) | Apache-2.0 [V header] | Written to produce Vulkan Std structs; `VkVideoParser`/`VkVideoDecoder` show the DPB management. C++. **Best for production.** |
| dav1d `src/obu.c` | BSD-2 | Only `dav1d_parse_sequence_header` is public. Frame-header parsing is tied to `Dav1dContext` and there is no Vulkan mapping, so it would need a fork. |
| libaom | BSD-2 + AOM patent license | The parser is entangled with the decoder. |
| Chromium `av1_decoder.cc` → libgav1 `ObuParser` | Apache-2.0 / BSD | Good, but brings libgav1 + Chromium glue. |
| GStreamer `gstav1parser` + vulkan av1dec | LGPL | Heavy. |

## 2. Which process decodes, sandboxes, plugin load

- **Safari:**
  - The AV1 capability is computed **in the WebKit GPU process** (`com.apple.WebKit.GPU`): `GPUConnectionToWebProcess` sends `.hasAV1HardwareDecoder = av1HardwareDecoderAvailableInProcess()` (= `VTIsHardwareDecodeSupported('av01')`, cached forever) to WebContent and the UI process [V WebKit main].
  - Decode happens through `VTDecompressionSession` in the GPU process [I]. Depending on the VT mode it may be wrapped into **VTDecoderXPCService**.
- **QuickTime Player:** an AVFoundation/MediaToolbox app (sandboxed Apple app). The decoder is wrapped into VTDecoderXPCService (nullmoth #349 tested this). macOS has no mediaserverd in this path [I].
- **IINA:** unsandboxed. mpv/FFmpeg `--hwdec=videotoolbox` decodes in-process. FFmpeg master has the AV1 VT hwaccel (`VTRegisterSupplementalVideoDecoderIfAvailable` + `av1C`, `RequireHardwareAcceleratedVideoDecoder`) [V]. Whether IINA's FFmpeg is recent enough is [I].

**VT wrap logic** [V disassembly, selection core 0x7ff812ce0713]:
- Candidates come sorted (`CFArraySortValues`; sorted by rating [I]).
- In "mode 1", a candidate is wrapped when **`VTAllowSandboxedDecode` != false (absent counts as true)**. The spec then gets **`DecoderID = the entry's CMClassImplementationID`** and is sent to the XPC service, which runs the selection again in "mode 2" (`VTRemoteDecodeServer_XPCServiceConnectionHandler`, edx=2).
- `avc1/avc3/vp09/...` sit on a separate no-wrap list behind a flag; `av01` is not on it.
- Consequence: **our entry must exist under the same ID both in the client and in VTDecoderXPCService.** The bundle route gives that automatically.
- Who triggers mode 1 (`VTDecompressionSessionCreateWithOptions`, `-0x138`) is [I].

**Sandboxes:**
- **VTDecoderXPCService** [V on this Mac, 27.0; 15 likely the same, I]:
  - `_SandboxProfile=VTDecoderSandboxProfile` with `(deny default)` + `(system-graphics)`;
  - `iokit-open-user-client (iokit-connection "IOAccelerator")`, `IOSurfaceRootUserClient`;
  - file-read `/Library/GPUBundles` and `/Library/Video/Plug-Ins`; writes only to `/private/var/folders`;
  - entitlement `disable-library-validation`.
  - There is **no** "IOAccel*" prefix rule; that one exists only in WindowServer's profile.
- **WebKit GPU process** [V `com.apple.WebKit.GPUProcess.sb.in`]: `iokit-connection "IOAccelerator"`. When the message filter is on, it allows everything with a report.
- **Our kext:** `class IntelXe : public IOService`, and xemac opens `IOServiceMatching("IntelXe")` [V]. This is **not** an `IOAccelerator` connection, so both sandboxes very likely refuse it [I, to be tested].
- **Fix:** NMXAccel (`NVAccel : IOGraphicsAccelerator2`) creates the `IOAccelIntelXeClient` for a new `type` (e.g. `'XE\0\0'`), with a carrier as in NVRM. xemac opens the NMXAccel service instead of `B580`.

**Plugin load and allow-list:**
- Metal maps the bundle in VTDecoderXPCService without creating a device (nullmoth comment, GH #175). The constructor runs in every Metal-using process.
- The decoder **creates its own Vulkan device** and does not use the Metal device, so **no allow-list entry is needed** [I].
- With the bundle route the plugin does not need to load at all.
- Mesa disk cache: point it at `/private/var/folders/...` (`confstr(_CS_DARWIN_USER_CACHE_DIR)`) or turn it off.

## 3. Will Safari use it?

**Capability:**
- `VTIsHardwareDecodeSupported(c)` = `VTSelectAndCreateVideoDecoderInstance(c, {RequireHardwareAcceleratedVideoDecoder:true}, out=NULL)`; true when the result is 0 or -12913 [V].
- With out=NULL, the core returns as soon as the candidate list is non-empty, **without calling the factory** [V 0x7ff812ce07b0 → 0xca6].
- `VTCopyAV1DecoderCapabilitiesDictionary` walks the av01 entries. If one is `IsHardwareAccelerated` and `VTIsHardwareDecodeSupported('av01')` is true, it builds a **hardcoded** dictionary:
  - profile 0;
  - `IsHardwareAccelerated`;
  - Max{Decode,Playback,HDRPlayback}Level = seq_level_idx 16/17/19 (assignment to keys [I]);
  - color depth and chroma arrays.

  [V disassembly] A per-decoder capability info dict is therefore unnecessary.

**WebKit:**
- `validateAV1Parameters` (MediaCapabilities / `isTypeSupported('av01…')`) uses that dictionary and gives `powerEfficient = IsHardwareAccelerated`. `SourceBufferParserWebM` accepts `V_AV1`/`av01` only when `av1HardwareDecoderAvailable()` [V WebKit main].
- The hackintosh's system WebCore soft-links `VTIsHardwareDecodeSupported`, `VTCopyAV1DecoderCapabilitiesDictionary` and `VTRegisterSupplementalVideoDecoderIfAvailable`, and contains dav1d (for WebRTC) [V strings].
- If Safari is updated from a cryptex, the WebKit copy may differ [I].
- MediaToolbox has av01/av1C parsing; `FVDUtilsDecoderCodecSupported` = `VTIsHardwareDecodeSupported` [V].

**YouTube:** on M3 Macs Safari gets AV1 when MediaCapabilities reports `supported && powerEfficient`. The same flags should make it serve AV1 here [I]. "Always prefer AV1" on youtube.com/account_playback helps the test.

**Ratings:**
- Our decoder is registered only for `av01`, so H.264/HEVC stay with Apple GVA (iGPU).
- For av01 the system has only `AV1DecoderSW.bundle` (`com.apple.videotoolbox.videodecoder.av1.sw`, no `VTIsHardwareAccelerated`) [V schema, on this Mac]. It is gated by `EnableAppleOnlySWAV1/RequireSWAV1` [V names].
- A hardware filter or `VTRating=1000` puts us on top [I for the ordering].

**Timing risk [I]:** WebKit caches the answer once per GPU process. If the Metal plugin route registers late, Safari sees "no AV1" for the life of that process. The bundle route removes this risk.

## 4. System-wide enablement

**Decoder bundle**, e.g. `/Library/Video/Plug-Ins/IntelXeAV1Decoder.bundle`:
- `CMClassImplementations[0]` = `{CMClassID "com.apple.videotoolbox.videodecoder", CMClassImplementationID "io.github.yusufklncc.intelxe.videodecoder.av1", CMFactoryFunction "IntelXeAV1_CreateInstance", CMMatchingInfo {VTCodecType "av01", VTIsHardwareAccelerated true, VTRating 1000?}, CMDependencies {IORegistryRequiredKey "IntelXeVideoDecode"}}`. These keys are the ones Apple's GVA bundles use [V].
- The kext publishes `IntelXeVideoDecode` once the VCS fuses are known, so without a B580 the entry is inactive [I].
- What search-path flag 1 means for `/Library/Video/Plug-Ins` (in `0x7ff812ce11dd`: access check + `FigRegistryAddSearchPathWithOptions`) is unknown → test S1.

**Kernel:**
- Today `gVideoWanted` (`debug.intelxe.video`) gates the engine list, and **the engine query itself calls `mediaUp()`** [V xe_core.cpp:981/1023]. Turned on by default, every Vulkan process (WindowServer included) would trigger the media GuC load.
- **Proposal:** always list VCS from the fuse info, and call `mediaUp()` only at the first `EXEC_QUEUE_CREATE(class=VIDEO_DECODE)` (already there at xe_core.cpp:605).
- Risk: a media-GuC failure at runtime breaks only video. Power gating stays off, so idle power rises a little.

**Mesa:**
- **One ANV build** (with codecs) for both Metal and the decoder.
- Under `HAVE_XEMAC`, `video_decode_enabled = true` (`anv_physical_device.c:375`), replacing the `ANV_DEBUG` dependency.
- Two ANV copies in one process (VTDecoderXPCService or the WebKit GPU process may run both Metal and the decoder) would mean two xemac connections, two VMs and twice the memory.
- Risks:
  - the Metal device sees an extra queue family; check that nvmtl's queue selection does not take the first family blindly [I];
  - a bigger dylib;
  - a regression in the Metal path, so keep the old library ready for rollback.
- **Alternative:** the decoder loads `libvulkan_intel_video.dylib`, which is safer for Metal but doubles resources.
- **Recommendation:** single build, staged after S3.

**Signing:**
- VTDecoderXPCService has DLV, so a third-party-signed bundle can load [I].
- Hardened Apple processes (Safari GPU process, QuickTime) cannot load the bundle **in-process**; that is fine, because they wrap to the XPC service.
- Per the memory notes, keep the "Mod-signed" practice. Ad-hoc must be tested.

## 5. Staged plan

| # | Stage | Effort | Result / test |
|---|---|---|---|
| S0 | Baseline on the hackintosh: small CLI `VTCopyVideoDecoderList`, `VTIsHardwareDecodeSupported('av01')`, `VTCopyAV1DecoderCapabilitiesDictionary`. In Safari, `navigator.mediaCapabilities.decodingInfo({…av01.0.08M.08…})` and `MediaSource.isTypeSupported`. Copy the 15.8.1 `VTDecoderSandboxProfile.sb` / `system.sb` for comparison | 0.5 day | Expected: false/NULL |
| S1 | **Stub decoder** (no Vulkan): the nullmoth vtable skeleton; StartSession accepts `av1C`; DecodeFrame takes a pool buffer, writes grey/frame number, emits. Two ways: (a) test app + `VTRegisterVideoDecoderWithInfo`; (b) `/Library/Video/Plug-Ins` bundle. Test: S0 queries, `VTDecompressionSession` on av01 MP4 samples, QuickTime Player with an av01 MP4 (grey picture = service wrap works), Safari MediaCapabilities + YouTube "Stats for nerds" `av01` | 1–2 days | Answers Q3 **before Vulkan**. Also log `IOServiceOpen("B580")` inside the stub: the sandbox test |
| S2 | Kernel/user access: NMXAccel newUserClient type → `IOAccelIntelXeClient` (carrier), xemac opens via NMXAccel; `IntelXeVideoDecode` registry key; VCS list without mediaUp | 2–3 days | Stub opens xemac in VTDecoderXPCService and the Safari GPU process |
| S3 | Real decoder in the **unsandboxed test app**: libavcodec (av1 + vulkan hwaccel, minimal LGPL dylib), `get_proc_addr` = ANV ICD, AVVkFrame → staging → memcpy into the pool buffer. Single ANV build + `video_decode_enabled=true` | 3–5 days | Test app plays av01 1080p/4K correctly (PSNR against dav1d) |
| S4 | Zero-copy: IOSurface host import + graphics-queue copy, semaphores/ownership | 2–4 days | No CPU copy; measure GPU write into userptr pages |
| S5 | System-wide: bundle + VTDecoderXPCService; QuickTime, Safari/YouTube, IINA (`mpv --hwdec=videotoolbox`). Seek/flush (FinishDelayedFrames), resolution change, 10-bit P010, film grain, several sessions at once, error recovery | 1–1.5 weeks | AV1 in Safari |
| S6 (optional) | Replace libavcodec with `NvVideoParser` (Apache-2.0) + own DPB/submit | 2–3 weeks | No LGPL dependency, smaller service footprint |

**Riskiest unknowns and cheap tests:**
1. **Does a third-party bundle in `/Library/Video/Plug-Ins` get loaded?** (flag 1, signing) → S1(b): see whether `VTCopyVideoDecoderList` lists it. If not, use the Metal-plugin route (S1(a) + a constructor in VTDecoderXPCService and the WebKit GPU process) and examine the timing issue.
2. **Can the sandbox open `B580`?** → the S1 stub logs an `IOServiceOpen` attempt from inside VTDecoderXPCService. Also try `sandbox-exec` with a profile that imports `system.sb` (system-graphics).
3. **Will the wrap carry our ID to the service, and which processes run in mode 1?** → in S1, read the stub's `getprogname()` log (which process the factory runs in).
4. **Does Safari 15.8.1 / the cryptex WebKit compile `ENABLE(AV1)` on x86, and does YouTube actually serve AV1?** → S1 JS test + "Stats for nerds".
5. **GPU write into userptr pages** (the "userptr RO" note) → S4: a small `vkCmdFillBuffer` into an imported IOSurface, then a CPU check.
6. **ANV video queue without TRANSFER, cross-queue copy** → `vulkaninfo` queue flags (`vk_videocaps` already exists).
7. **Media GuC stability across sessions, processes and sleep/wake** → in S3, play 2 hours plus parallel sessions plus sleep. Run the hang watcher in the background.
8. **WindowServer upload cost when the display is on the B580** (IOSurface sysmem → VRAM, ~8 ms at 4K) → measure 4K60 in S5.

## References
- [WebKit `AV1UtilitiesCocoa.mm`](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/cocoa/AV1UtilitiesCocoa.mm), `PlatformMediaEngineConfigurationFactoryCocoa.cpp`, `GPUConnectionToWebProcess.cpp`, `com.apple.WebKit.GPUProcess.sb.in`
- [nullmoth PR #349](https://github.com/nullmoth/nvidia-macos-driver/pull/349); release v2.6.3 `libnvdec_hevc.dylib`
- [Khronos Vulkan-Video-Samples](https://github.com/KhronosGroup/Vulkan-Video-Samples) `vk_video_decoder/libs/NvVideoParser`
- [FFmpeg `videotoolbox.c`](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/videotoolbox.c) (AV1 VT hwaccel)
- [Apple Developer Forums 722933](https://developer.apple.com/forums/thread/722933) (AV1DecoderSW.bundle)
