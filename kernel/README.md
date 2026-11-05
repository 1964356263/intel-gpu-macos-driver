# Kernel extensions

## IntelXe/ — GPU core (`io.github.yusufklncc.IntelXe`, IntelXe.kext)

A plain IOKit kext, without Lilu, for the Arc B580 (Battlemage BMG-G21, `8086:e20b`). It follows Linux `drivers/gpu/drm/xe` closely.

- **Bring-up:**
  - pcode init status, forcewake;
  - PAT/MOCS tables (xe2), GT and engine workarounds and tunings;
  - GuC 70.72.1 load with ADS, CT, SLPC and GuC RC;
  - golden contexts per engine class;
  - MSI interrupts;
  - media GT (VCS0/VCS2, VECS) with its own GuC, HuC 8.2.10 authentication and media SLPC.
- **Memory:**
  - VRAM buddy allocator (drm_buddy style) and GGTT range allocator;
  - 5-level PPGTT with 64 KB and 2 MB/1 GB leaves;
  - a CPU-visible BAR2 window, with buffers spilling to system memory when it is full;
  - userptr, including read-only imports.
- **uAPI:** the xe uAPI that Mesa's ANV uses (`uapi/xe_drm.h`), over an IOUserClient (`IOAccelIntelXeClient`):
  - queries, GEM create/mmap, VM bind (async), exec queues on GuC submission;
  - DRM syncobjs (binary and timeline).
  - `uapi/intelxe_drm.h` adds IOSurface implicit fences (the dma-resv model) and scan-out pinning for the display side.
- **Robustness:** job watchdog / TDR, GT reset, shutdown quiesce, sleep/wake (`intelxePowerEvent`).

**Version in this repository: `rb7u`**, the kernel of the 0.1.x releases (renamed to IntelXe; tested on macOS 26.7.1).
It is `rb7t` (VRAM-shared IOSurfaces fixed at boot, purgeable BOs, shared BOs, external fds behind `debug.intelxe.fds`)
plus `rb7u` (macOS 26 starts drivers while the card is still leaving its reset: wait for config space, read the VRAM
size again). The earlier steps, each a separate patch in the development tree:

| Step | What |
|---|---|
| `ph` | `pi` + IODMACommand-based DMA (VT-d ready) + `intelxePowerEvent` for IntelXeFB's sleep/wake save/restore |
| `pv` | **BAR window under pressure.** 32 MB of the 1 GB CPU-visible window is kept for page tables (a full window had made every VM_BIND fail with ENOMEM); one memory descriptor per CPU map (GEM_MMAP_OFFSET returns a cookie), so `IOConnectUnmapMemory64` finds and removes VRAM mappings (it never did); cheap eviction scans; `debug.intelxe.vram` (window, VRAM and system BOs per process) and window counters in `debug.intelxe.stats` |
| `pv2` | EXEC waits behind the VM's kernel fences (BO clears), as `xe_exec` waits on the VM resv KERNEL slot |
| `pv3` | a CPU map of a BO beyond a full window moves it to system memory (`boMoveSys`, xe's fault migrate to TT) instead of failing with ENOSPC |
| `sv1`-`sv7` | VRAM-shared IOSurfaces (`uapi/intelxe_surfvram_kabi.h`, the registry NMXAccel and the plugin use; on at boot with `intelxe_surfvram=2`, as the install guide sets it, otherwise off until `debug.intelxe.surfvram` is set) |

What is not done yet for the window: a BO the CPU has mapped never leaves it (an IOKit user mapping of a physical range
cannot be pointed elsewhere), so the window is first come, first served, with spills to system memory.

## IntelXeFB/ — display (`io.github.yusufklncc.IntelXeFB`, IntelXeFB.kext, class `IntelXeFramebuffer`)

An IOFramebuffer for the B580's DisplayPort outputs (display IP 14.01, C20 PHYs).

- **Mode setup:**
  - takes over the mode the GOP lit;
  - reads EDID over DP AUX;
  - scaled modes through the pipe scaler;
  - the modes and refresh rates the monitor's EDID offers (all blocks, Linux's drm_edid parsing; 120 modes on the test
    monitor, the same rates as Windows);
  - Adaptive-Sync (VRR) with an LFC pacer.
- **Link:** retraining and a full modeset with C20 PLL programming (`IntelXeLink.cpp`).
- **Cursor:** hardware cursor.
- **Pipe gamma:** for IOPresentment.
- **Flips:** real flips from scan-out buffers pinned in VRAM.
- **Power:** sleep save/restore.
- **Boot-time arming:** at boot it matches from the AuxKC and arms acceleration in the kernel together with NMXAccel ("boot1"), with an NVRAM panic-loop guard (`intelxe-guard`).

**Version in this repository: v10m**, the framebuffer of the 0.1.x releases: boot1 + v9 + v10b (`intelxefbRunGated`: NMXAccel's pipe registration inside IOGraphics' gate order; detailed timings answered with their mode size) + v10c (boot-guard fix) + the later steps up to v10m (modes from the EDID).

Boot guard (`intelxe-guard` in NVRAM): after two accelerated boots in a row that end inside their first minute the next boots arm with
NMXAccel's safest settings (`IntelXeFBAccelSafe`); four in a row turn acceleration off for the next boots (on macOS 26 that leaves the Apple
logo on screen: WindowServer uses no display without the accelerator's pipe) (`intelxe-accel-off`, until `sudo nvram intelxe-accel-off=ok`; `nvram -d` leaves it in place on macOS 26). One such boot only makes
the next one try again: it may have been a power cut. On x86 macOS the kernel's NVRAM writes after boot stay in memory until a clean
shutdown (AppleEFINVRAM ignores the SYNCNOW keys, and calling `IODTNVRAM::sync()` from IntelXeFB's start hung the boot), so `install.sh`
adds a LaunchDaemon that writes the cleared guard with `nvram` once per boot; tested on the B580 with a power cut (5 Nov). Since v10c "healthy" needs WindowServer itself: its
IOFramebuffer server connection (opened by the process named WindowServer, the last time 45 s ago or more), steady VBL
clients, and for the accelerated stage at least 120 NMXAccel frame calls. Before, VBL clients and one frame call were
enough, and NMXAccel's display pipe provides both on its own: at a boot where WindowServer deadlocked before it started
the guard still cleared.

Scripts (`scripts/`):
- `intelxe-accel.sh`: arms WindowServer acceleration by hand, used by builds before boot1.
- `intelxefb-load.sh` + `io.github.yusufklncc.intelxefb.plist`: the LaunchDaemon loader for builds before boot1; a no-op with boot1.
- `install-boot1.sh` / `rollback-boot1.sh`: switch the installed kexts to boot1 and back. Paths inside them are those of the development machine.

Licence: `IntelXeFB.cpp` is derived from nullmoth's NMIntelFB/NVRMFB and is therefore PolyForm Noncommercial 1.0.0. `IntelXeLink.*` is MIT. See `IntelXeFB/LICENSE`.

## Building

```sh
firmware/fetch.sh                                   # GuC/HuC blobs (not in git)
git clone https://github.com/acidanthera/MacKernelSDK external/MacKernelSDK   # or MACKERNELSDK=/path
python3 kernel/IntelXe/build.py                        # -> build/IntelXe.kext, build/IntelXeFB.kext
python3 kernel/IntelXe/build.py --debug                # -O0, INTELXE_DEBUG=1 (destructive bring-up steps, batch dumps)
python3 kernel/IntelXe/build.py --only IntelXe --output /tmp/k
```

Built on an Apple Silicon Mac with the Command Line Tools (x86_64 kext target).
