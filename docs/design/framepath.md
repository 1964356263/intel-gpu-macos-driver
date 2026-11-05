# B580 accelerated desktop: frame path and a plan for 180 Hz

> Design note with its date: it records the plan and the state of that day, not the current status. The current
> state is in the README and `docs/devices/b580.md`.

[V] = verified in code (file:line), [I] = inferred (not proven by code or measurement). Paths: `nm/` = src/nullmoth, `b5/` = src/b580. One full frame at 2560x1440 BGRA is **14.75 MB**.

## 0. Summary

On the B580 every WindowServer IOSurface is a **private Vulkan image in VRAM**, and its pixels are copied back to system memory after every GPU write. Each frame therefore makes **two full-screen GPU→sysmem readbacks, each followed by a 14.75 MB CPU memcpy**, plus **one more 14.75 MB CPU copy in the kernel** into BAR2. WindowServer waits synchronously for the first two. The GPU itself does little, which is why the GPU clock makes no difference. Nothing is flipped, and no GPU fence is used anywhere on the path.

## 1. One frame, end to end

1. **Client windows.** Each app's IOSurface lives in system memory owned by IOSurface.kext [I]. On B580 the plugin turns off surface sharing for every non-NVIDIA GPU: `nvmtl_gpu_headless()` returns 1 (nm/plugin/nvmtl_vk.c:1961-1966), so `nvmtl_vk_surface_share_on()` is 0 (:1970-1980) [V]. Each process then wraps the surface as a private image (`nvmtl_surface_image_create`, nm/plugin/NVMTLDevice.m:961-998) whose memory is device-local, so it is VRAM (nvmtl_vk.c:1801-1806) [V].
   - An app that draws with Metal reads its image back to the IOSurface after each frame (surface-out, below). This happens in the app's process.
   - WindowServer uploads a window again only when the IOSurface seed has changed (`nvmtlSurfaceIn`, NVMTLObjects.m:1227-1255). The upload is `nvmtl_vk_image_write_host` (nvmtl_vk.c:6330-6356): it imports the pages as host memory, which becomes `DRM_XE_VM_BIND_OP_MAP_USERPTR` in the kernel (b5/xe_core.cpp:1135-1172, system PTEs at :529-533). Then the GPU copies them into the image, and the encode thread waits synchronously for that copy [V].
   - **While you drag a window nothing is uploaded**, because the seeds do not change [V, seed check at :1232].
2. **Core Animation encode** (~4.5 ms) records the composite into a WindowServer IOSurface texture, which is again a private VRAM image [V for all IOSurface textures; I that the composite target is an IOSurface].
3. **`commitAndWaitUntilSubmitted`** (NVMTLObjects.m:5048-5054): in WindowServer, `nvmtl_ws_kernel_waits()` is false, so the call does `commit` + `waitUntilCompleted` [V]. The reason is that `nvmtl_vk_surface_gpu_mark` returns 0x80000002 (nvmtl_vk.c:2003-2007): `pnvk_surface_dirty` is a `dlsym` of `nvmtl_nvk_surface_dirty` from the ICD (:717-718), and ANV does not export it [V: absent from patches/mesa]. "Completed" includes surface-out. The worker runs `nvmtl_vk_submit_wait` (NVMTLEventSync.m:645), **then** `nvmtlSurfaceOut` for every written surface (:657), and only after that `FinishExecution` [V]. Surface-out (NVMTLObjects.m:1287-1320) is `IOSurfaceLock` + `nvmtl_vk_image_read` (nvmtl_vk.c:6402-6427):
   - GPU copies the image (VRAM) into a staging buffer in host-visible system memory (`nvmtl_vk_stage`, :1455; `memtype` prefers non-device-local, :1101-1108);
   - a second `submit_wait`;
   - **CPU `memcpy` of 14.75 MB from staging into the IOSurface pages (:6426). This is the `_platform_memmove` in the samples** [V].
4. **`Display::Present` → `RunGPUDisplayPipe` → `RunFullDisplayPipe` → `DisplaySurface::AccessComplete`.** This is CoreDisplay's own GPU pass [V, CoreDisplay disassembly, scratchpad cdk.s:107639-110016; selectors resolved]:
   - `renderCommandEncoderWithDescriptor:` on the DisplaySurface's texture, then `drawPrimitives`, `endEncoding`, `commitAndWaitUntilSubmitted`, `waitUntilScheduled`.
   - `RunGPUDisplayPipe` decides what to do on the GPU by asking `IOPCapabilities::SupportsCSC / SupportsLinearization / IsEOTFSupportedInHW / SupportsPixelFormat / upscaling` (cdk.s:194501+) [V].
   - Our capability dictionary advertises only Flags/BlendType/Width/Height/PixelFormats (nm/kexts/NVRM/accel/nvrm-accel.cpp:1278-1296) [V], so colour work falls to the GPU pass [I].
   - That pass renders a full-screen DisplaySurface, which is a second private image, and then waits for completion **including a second full surface-out** (GPU copy + 14.75 MB memcpy).
5. **IOP transaction.** The family's `submitTransaction` calls our `performTransaction` and completes the transaction right away when `isTransactionComplete` is true. Its disassembly calls `enable_pipe_event_interrupt` / `sendNotification` / `sendAsyncResult64` (sys.kc) [V call graph, I exact branch]. `performTransaction` (nvrm-accel.cpp:1166-1262) runs as follows:
   - The flip path is dead on B580: `gIopFlip=0` (:1360), and `nvAccelIopFlip` also requires an NVRMNVDAFramebuffer (:2115-2117) [V].
   - `nvSurfWaitReady` returns at once because no marks exist [V].
   - `nvAccelSurfCopyReady` passes [V].
   - `iopMapSurface` maps the IOSurface's system-memory pages read-only (:1132-1148) [V].
   - **CPU copy of 14.75 MB with 32-bit volatile loads and stores into IntelXeFB's write-combined BAR2 mapping** (:1236-1242) [V]. That mapping is `nvScanoutInfo` (b5/fb/B580FB.cpp:509-520, WC map at :708; IntelXeFB line numbers as of this report, the file was being edited) [V].
   - `isTransactionComplete` is `gNvIop && !asyncBusy`, which is true at once (:1155-1159) [V]. So completion is immediate, and the copy is paid synchronously by the thread that submits [I which thread].
6. **Scanout.** The plane keeps scanning the GOP surface: GGTT 0xfc000000 → DPA 0 → BAR2 0x4000000000. PLANE_SURF is never rewritten per frame [V].

The legacy page-flip path does not run in IOP mode [I; check that both counters stay flat while dragging]. That path is `submitSwapCopy` → `nvAccelCopyToScanout` (nm/.../nvaccel_stubs.h:107-113, nvrm-accel.cpp:2503-2557) and `submitCopyForward` → `nvAccelCopyRects` (stubs.h:145-149, :2571-2602), both CPU copies counted by `nmxaccel_scanout_copies` / `nmxaccel_copy_forwards`.

## 2. Surfaces: memory and who touches them per frame

| Surface | Memory | GPU access | CPU access per frame |
|---|---|---|---|
| Client window IOSurface | system memory (IOSurface.kext) [I] | upload only when the seed changes: userptr import + GPU copy | Metal apps: memcpy from staging in the app; WindowServer: none while dragging |
| WindowServer private image of every IOSurface | VRAM, device-local, optimal tiling (nvmtl_vk.c:1801) | rendered into, sampled | none (readback goes through staging) |
| Composite IOSurface (system copy) | system memory [I] | none | **14.75 MB memcpy write** (surface-out) |
| CoreDisplay DisplaySurface (system copy) | system memory [I] | none | **14.75 MB memcpy write** (surface-out), then **14.75 MB read** by the kernel IOP copy |
| Framebuffer resource (`initFramebufferResource`, nvrm-accel.cpp:870-923) | the GOP scanout in BAR2/VRAM (`fPhys`). With nmxaccelfb=4 the aperture is an IODeviceMemory over BAR2 (:939-958) | none | **14.75 MB WC write** (IOP copy). Never read per frame [V for the IOP path] |
| `nvAllocVram` memory (IntelXeFB.cpp:522-535) | wired, contiguous system memory with a kernel VA (cached) | **none**: no GPU mapping. NMX `commitIntoGPUPageTable` is a no-op with placeholder VAs (nvrm-accel.cpp:2274-2296, 2334-2337) | only family/WindowServer CPU paths [I]; not on the IOP frame path |

`NMXResource::pageoff` falls back to the family's own pageoff, because `nvAccelRmHandles` fails: IntelXeFB does not answer `NVRM_GPUVA_FN_HANDLES` (IntelXeFB.cpp:508-544; nvrm-accel.cpp:1852-1855) [V].

## 3. Per-frame copies (dragging a window)

| # | Copy | Where | Size | Cost (est.) |
|---|---|---|---|---|
| 1 | composite image → staging (GPU), plus submit_wait | plugin worker | 14.75 MB | ~1.2 ms PCIe + wait |
| 2 | staging → composite IOSurface (CPU memcpy, nvmtl_vk.c:6426) | plugin worker | 14.75 MB | ~1.5-2 ms |
| 3 | DisplaySurface image → staging (GPU) | plugin worker | 14.75 MB | ~1.2 ms |
| 4 | staging → DisplaySurface IOSurface (CPU memcpy) | plugin worker | 14.75 MB | ~1.5-2 ms |
| 5 | IOSurface → BAR2 WC (32-bit volatile CPU loop, nvrm-accel.cpp:1241) | kernel, performTransaction | 14.75 MB | ≥2.5 ms at 6 GB/s |
| (6) | surface-in for changed windows (userptr + GPU copy + wait on the encode thread) | WindowServer main thread | window size | 0 while dragging |

WindowServer waits for #1-#4. That roughly accounts for the measured 5 ms + 8 ms.

## 4. What AccessComplete waits for

There is no kernel event and no fence. `AccessComplete` → `commitAndWaitUntilSubmitted` → (plugin, WindowServer, no kernel marks) `waitUntilCompleted`. The plugin execution worker signals this through `nvmtlFinishExecution` after three things have happened [V, NVMTLEventSync.m:641-660]:
- the render part's `vkWaitForFences` (inside `nvmtl_vk_submit_wait`);
- the second submit_wait of the readback;
- the CPU memcpy.

## 5. Plan, smallest first

Budget at 180 Hz: **5.56 ms**. Before every stage, measure:
- Δ`debug.nmxaccel_iop_ok` over 10 s of dragging;
- `sample WindowServer 5`, main thread;
- the plugin log line "G13 surface-out … ms".

Add a kernel counter `nmxaccel_iop_copy_us` (max/avg). Check the kernel log for "iop: K6 … from the IOSurface's memory".

### Stage 1: cut the CPU copies (low risk, ~45 → ~60 fps est.)
- **Readback straight into the IOSurface pages.** Add `nvmtl_vk_image_read_host`, the mirror of `image_write_host`: import the locked IOSurface pages with `buffer_import_host` (MAP_USERPTR, writable) and point `vkCmdCopyImageToBuffer` at them. The staging buffer and the memcpy at :6426 go away. Fall back to the old path when the import fails. Cache the import per IOSurface, since wiring 3600 pages on every frame costs too. Files: plugin/nvmtl_vk.c, NVMTLObjects.m:1308. Removes copies #2 and #4 (~3-4 ms).
- **Faster kernel copy.** Replace the volatile 32-bit loop (nvrm-accel.cpp:1236-1242) with `memcpy` per row (rep movsb, WC-friendly) or 64-byte SSE non-temporal stores. ~1 ms.
- Risk: none for VRAM reads. The IOSurface lock is already held across the import.

### Stage 2: WindowServer stops waiting (lever d; ~90-120 fps est.)
The kernel side already exists:
- `nvSurfMark` / `nvSurfWaitReady` (nvrm-accel.cpp:1408-1453);
- `nvSurfGpuEscape`, which runs **before** the RM-handles check (:1729-1744). So it works without NVRM.

Only the transport is missing:
- **IntelXe.kext:** a new external method on `IOAccelIntelXeClient` (WindowServer's sandbox allows IOAccel* classes). It calls `NMXAccel->callPlatformFunction("nvSurfVram", esc{surfaceID, plane=GPU_MARK|pending}, task, NVRM_ESC_SURF_DIRTY)`.
- **Mesa patch 0006:** export `nvmtl_anv_surface_gpu_mark()`, which calls that method through xemac.
- **Plugin:** `nvmtl_vk_surface_gpu_mark` (nvmtl_vk.c:2003) uses that export when the vendor is 0x8086. Then `commitAndWaitUntilSubmitted` becomes `waitUntilScheduled` in both places, the composite and AccessComplete.
- The "late" ordering is correct here: marks are released after surface-out (`nvmtl_ws_mark_ready`). `nvmtl_vk_accel_surface_wait` looks for the class name `NVAccel` (nvmtl_vk.c:2011), so on NMXAccel it already stays off [V].

**`performTransaction` must become asynchronous at the same time.** Otherwise `nvSurfWaitReady` just blocks the submitting thread. Do the wait and the copy in a `thread_call` (pattern: `nvAccelIopAsyncStart`/`Run`, nvrm-accel.cpp:2023-2111), return "incomplete" from `isTransactionComplete` while it is busy, and call `signalTransactionInterrupt` when done.

Better (optional): pass the xe syncobj and timeline point with the mark, so the kernel waits on the GPU's own completion through the B580 IRQ instead of the plugin's completion thread.

Risks:
- The 100 ms timeout in `nvSurfWaitReady` copies unfinished pixels. Count timeouts.
- A mark that is never released blocks frames. Check `nvaccel_surface_gpu_timeouts`; it needs registering under NMX.

The ceiling becomes the plugin worker's serial chain of 2 renders + 2 readbacks + the kernel copy.

### Stage 3: real flips (lever c; target 150-180 fps)
- **Scanout-capable image.** For WindowServer surfaces that can be the IOP plane (BGRA, mode size, bytesPerRow % 64 == 0), the plugin creates the private image with these properties:
  - **linear** tiling, or Tile4 with a matching PLANE_CTL;
  - **uncompressed** (Xe2 flat-CCS is chosen by PAT; linear scanout cannot read CCS) [I: check which PAT ANV uses];
  - in VRAM;
  - row pitch = the IOSurface's bytesPerRow.
  BGRA in memory is DRM XRGB8888, PLANE_CTL format 8, the format already in use.
- **Register it.** A Mesa export gives the GEM handle and offset of the image's memory. A new B580 call (`SCANOUT_BIND`: handle, offset, stride, size, surfaceID) does the rest:
  - checks `bo->vram` (a VRAM BO is one contiguous DPA range: first-fit `vramAlloc`, xe_core.cpp:105-122 [V]);
  - pins it;
  - GGTT-maps it with DM PTEs (as IntelXe.cpp step 23 does), 4 KB alignment for linear (Linux `tgl_plane_min_alignment`, skl_universal_plane.c:582-618 [V]);
  - publishes surfaceID → GGTT address.
- **Flip.** `performTransaction`: if the plane's surfaceID is registered, wait for its GPU mark or fence (stage 2), then call IntelXeFB `intelxeFlip(ggtt, stride)`, which writes PLANE_STRIDE, then PLANE_SURF. The write latches at the next start of vblank, so there is no tearing as long as rendering has finished. `isTransactionComplete` stays false until `PLANE_SURFLIVE` (0x701AC + pipe·0x1000) equals the new address. Check it in IntelXeFB's vblank-locked VBL callback, then call `signalTransactionInterrupt`. Keep the previous front buffer referenced until then (`gIopFlipPrev` pattern). Flip back to the GOP surface on mode change or unregister (`nvAccelIopHome` pattern).
- **Surface-out leaves the critical path.** The display surfaces still need surface-out for screenshots and recording [I]. Run it asynchronously, through the copy engine into the imported pages, and never let the flip wait for it. Copies #3-#5 are gone; #1 can also go async.
- Risks:
  - a wrong PAT or tiling gives garbage on screen, so keep a fallback to the copy path;
  - GGTT space is needed for ~3 × 15 MB;
  - the GOP surface must stay reserved;
  - screencapture can return stale content: test it.
- Verify:
  - a new `nmxaccel_iop_flips` counter;
  - the `debug.intelxefb_thumb` view;
  - `sample` shows no memmove and no `waitUntilCompleted`.

### Stage 4: skip CoreDisplay's GPU pass [I, research first]
If the plane advertises CSC, degamma and regamma (and IntelXeFB implements pipe CSC and gamma LUTs), `RunGPUDisplayPipe` may scan out the composite directly with no `AccessComplete` pass. Map the capability keys from iopk.s first. Risk: wrong colours if we claim support and ignore the matrices.

### Stage 5: CPU encode (~4.5 ms)
- **(e) Descriptor churn.** Descriptor pools are created with `FREE_DESCRIPTOR_SET_BIT` (nvmtl_vk.c:2386), and one snapshot set is allocated per draw (:2916-2960). ANV's freeable pools use a heap allocator. Switch to per-command-buffer linear pools reset at completion, or to `VK_KHR_push_descriptor`. Verify by the share of `anv_AllocateDescriptorSets` in samples.
- **Surface-in.** Cache userptr imports per IOSurface and submit without waiting, ordered with a semaphore before the composite. This helps scrolling and video, not dragging.

### Verdicts on the proposed levers
- **(a) BAR2-physical userptr → VRAM PTE.** Not on today's path: nothing imports a BAR2 CPU mapping, and stage 3 uses GEM handles instead. It is still a cheap safety fix. Today, a BAR2 VA passed to `vmMap` would become a *system* PTE pointing at the GPU's own BAR (xe_core.cpp:529-533). In MAP_USERPTR, test whether each `getPhysicalSegment` falls inside `[bar2Phys, +len)`. If so, write `(phys − bar2Phys) | 1 | 1<<11`, or refuse with ENOMEM.
  - Whether `prepare()` succeeds on an IODeviceMemory user mapping is [I]: XNU's `vm_object_iopl_request` has a phys-contiguous/UPL_DEVICE_MEMORY branch. Test it with an mmap'd VRAM BO (xemac) passed to MAP_USERPTR, and log `prepare` and `phys`.
- **(b) `nvAllocVram` in real visible VRAM.** **Reject it as a standalone step.**
  - That memory is not on the GPU path.
  - Several CPU **read** paths take its kernel VA: the `performTransaction` "fromRes" branch (:1194-1201), `nvAccelCopyRects` (:2571), the swap-probe samplers (:2403-2475), and possibly family pageoff and WindowServer CPU blits [I]. Each would drop to 3.7 MB/s.
  - Revisit only as part of a full port of surface sharing ("item 7": one VRAM BO per IOSurface, imported by every process's ANV, CPU locks paged off by the B580 copy engine), after auditing every reader.
- **(c)** stage 3. **(d)** stage 2. **(e)** stage 5.

### Expected outcome (estimates)
| After | fps |
|---|---|
| Stage 1 | ~55-65 |
| Stage 2 | ~100 |
| Stage 3 | ~150-180 |
| Stages 4/5 | the headroom needed to hold 5.56 ms with apps redrawing |
