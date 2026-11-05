# intel-gpu-macos-driver

**English** · [Türkçe](README.tr.md)

> [!NOTE]
> **Built with AI.** This project is developed with AI assistance. The code in this repository (the kernel driver, the
> changes to nullmoth and Mesa, the tools and the documentation) was written by Anthropic's **Claude Opus 5.5** model at
> the **High** effort level, under the direction of the maintainer, who tests every build on the real hardware.
> Third-party code it builds on (nullmoth, Mesa, Linux, FFmpeg) keeps its original authors.

**A Metal driver that runs Intel Arc graphics cards on macOS.** It brings the GPU up the way Linux's `xe` driver does,
runs Mesa's Vulkan driver (ANV) on top of it, and implements Metal on Vulkan, so WindowServer, Metal apps and games,
and VideoToolbox video run on the Intel card. Today it runs on the **Arc B580** on **macOS 26 Tahoe** (x86_64,
OpenCore).

<p align="center">
  <img src="docs/images/about-this-mac.png" width="27%" alt="About This Mac showing the Intel Arc B580 with 12 GB">
  <img src="docs/images/desktop.png" width="71%" alt="The macOS desktop composited on the Arc B580">
</p>

| | On the Arc B580 (macOS 26.7.1) |
|---|---|
| Desktop | composited on the GPU, 165 fps window dragging on a 180 Hz monitor, VRR |
| Geekbench 7 | Metal **92 898** · OpenCL **86 920** (80–84% of the same card's Vulkan / OpenCL scores on Windows) |
| Video | H.264 / HEVC / AV1 / VP9 decode bit-exact and faster than Windows up to 4K; H.264 / HEVC / AV1 encode |
| Vulkan CTS | 3.15 M cases, no hangs: 1.77 M pass, 84 fail |

> [!WARNING]
> **Experimental.** One card is supported and it is tested on one machine. Installing needs relaxed system security
> (SIP and AMFI settings, unsigned kexts), and a bad build can stop the Mac at boot. Keep a USB stick with a working
> OpenCore EFI before you try it. Releases are unsigned and come without support.

## Will it run on my Mac?

| | Supported | Notes |
|---|---|---|
| GPU | Intel Arc **B580** (8086:E20B) | other Intel GPUs: see [Project status](#project-status); nothing is claimed before it runs |
| macOS | **26 Tahoe** (tested on 26.7.1); 15 Sequoia (built from the same sources, not re-tested since the move to Tahoe) | x86_64 only |
| Machine | a PC with OpenCore (tested: Z790, i7-14700K) | Above 4G decoding and Resizable BAR on |
| Monitor | one DisplayPort monitor on the B580 | a second monitor is not supported yet |
| Apple Silicon | no | Apple Silicon Macs cannot take a PCIe GPU |

## Install

You prepare everything from Windows, Linux or macOS; no Mac is needed. The full guide is
[`release/README-INSTALL.md`](release/README-INSTALL.md) (also in each package). In short:

1. Install macOS with a plain OpenCore EFI ([Dortania's guide](https://dortania.github.io/OpenCore-Install-Guide/); the
   test machine's configuration without its serial numbers is in [`efi/sample-z790/`](efi/sample-z790/)).
   The installer runs on the B580's firmware output, without acceleration; no integrated GPU is needed.
2. In `config.plist`: SIP, the AMFI boot-arg, two quirks and `ReconnectGraphicsOnConnect = false` (otherwise
   OpenCore's RELEASE build panics the boot).
3. On macOS: the **IntelXe Manager** app from [Releases](../../releases) downloads the package for your version and
   installs it, or run `sudo ./install.sh --apply` from the package yourself. Either checks your setup first, backs up
   what it replaces and can undo the install.
4. In the EFI: `IntelXe.kext` and an ACPI table with your board's path, then reboot with the monitor on the B580. The
   app's EFI page or `efi.sh` does it from macOS on the PC, `IntelXe-EFI.ps1` (in `-efi.zip`) from Windows, in the
   EFI you point it to; each backs up the EFI first and changes only what the driver needs.

Later releases install over the old one from the app's Driver page.

To build everything yourself, see [Building from source](#building-from-source).

## What works

- **Desktop:** WindowServer composites on the GPU with real page flips; transparency, blur and animations are
  accelerated. One monitor over DisplayPort, all of its modes and refresh rates, VRR, hardware cursor, sleep and wake.
- **Metal:** apps, Chrome and games; the Metal 3 feature set including ray tracing (acceleration structures, ray
  queries, curves) through Mesa's `intel-rt`. Translated shaders are cached on disk and survive reboots and driver
  updates.
- **OpenGL and OpenCL** through Apple's GL-over-Metal and OpenCL-over-Metal (the default). OpenGL also runs through
  Mesa's Zink for applications that open their context with GLFW/EGL (LWJGL 3 games such as Minecraft): the optional
  `-zink-gl.zip` ([`zink-gl/`](zink-gl/README.md)).
- **Safari** on the GPU with the optional copy of the driver on the system volume (Safari's GPU
  process may only load code from there); desktop widgets and the Dock's icons on the GPU.
- **Video:** VideoToolbox decoders for H.264, HEVC, AV1 and VP9, and encoders for H.264, HEVC and AV1, all on the GPU,
  for QuickTime, OBS, HandBrake and ffmpeg's `videotoolbox` encoders.
- **GPU recovery:** a hung job resets only its engine; the desktop keeps running.

### Known issues

- Only 1 GB of the card's 12 GB is CPU-visible (macOS cannot map a larger BAR). The driver keeps that window for what
  needs it and puts background processes' buffers in system memory; many GPU-heavy apps at once can still fill it.
- Without the system-volume copy Safari runs on macOS's software path, where some elements with CSS colour filters
  are not drawn (a CoreGraphics problem without a Metal device; the install guide has the workaround).
- The first seconds after the first login stutter while shaders are translated for the first time.
- After a restart, the login screen shows a light grey band behind "Your password is required to log in".
- Command-line tools whose first Metal use is a VideoToolbox encode (ffmpeg) do not see our encoders in their first
  session; apps that bring Metal up first (OBS, QuickTime, HandBrake) do.

## Compared with Windows

The same card in the same machine, Intel's Windows driver against this driver
([full tables](docs/devices/b580.md)):

| | Windows | macOS (this driver) |
|---|---|---|
| Geekbench 7 GPU | Vulkan 111 056 · OpenCL 108 544 | Metal 92 898 · OpenCL 86 920 |
| Video decode up to 4K | reference | bit-exact and faster |
| Encode quality against Intel QSV (BD-rate) | reference | better for HEVC and AV1; H.264 within 1.5% |
| Minecraft Java 1.21.1, Sodium + Iris + BSL (HIGH), windowed, same spot | 214–218 fps (Intel's OpenGL) | 197–205 fps (Zink) |
| The same without a shader pack | 700–1000 fps | 1400–1500 fps (Zink) |

## How it works

```
 apps / WindowServer (Metal, Core Animation, OpenGL-over-Metal, OpenCL-over-Metal)
        │
 NVMTLDriver.bundle ── Metal driver plugin (nullmoth, modified)            nullmoth/plugin
        │   └── libnvmtl_translate ── AIR → SPIR-V shader translator        nullmoth/translator
        │
 Mesa ANV (libvulkan_intel.dylib) ── Vulkan + Vulkan Video, xe backend      mesa/  (+ user/xemac)
        │   xemac: xe uAPI over an IOUserClient instead of /dev/dri
        ▼
 NMXAccel.kext ── IOAccelerator for WindowServer; hands out the xe client   nullmoth/kexts/NVRM/accel
 NMXAGDC.kext  ── AppleGraphicsDeviceControl (display pipe for IOPresentment) nullmoth/kexts/NVRMAGDC
        │
 IntelXeFB.kext ── IOFramebuffer: modes, EDID, link training, VRR, flips    kernel/IntelXeFB
        │
 IntelXe.kext ── GPU core: GuC/HuC, GGTT/PPGTT, VRAM, engines, xe uAPI      kernel/IntelXe
        ▼
 Intel GPU (today: Arc B580, BMG-G21: graphics 20.01, media 13.01, display 14.01)
```

From the hardware up:
- **IntelXe.kext** brings the GPU up the way Linux `xe` does (GuC submission on every engine, SLPC power management,
  HuC, VRAM, page tables, GPU reset recovery) and offers the same xe uAPI that Mesa's ANV already speaks. Hardware
  knowledge is organised per IP version, as in `xe`.
- **IntelXeFB** drives the display.
- **NMXAccel and NMXAGDC** give WindowServer the accelerator and display-pipe services it expects from a GPU.
- **The Metal plugin** implements Metal on Vulkan and translates Metal's AIR shaders to SPIR-V.

The Metal plugin, the shader translator and the two NMX kexts come from
[nullmoth](https://github.com/nullmoth/nvidia-macos-driver), a Metal driver for NVIDIA cards, adapted here to Intel
(`nullmoth/CHANGES.md`).

## Project status

The goal is Intel GPUs on macOS in general; the B580 is today's development card. The table shows, per platform, what
Intel's own Linux stack offers (read from source only) and our status: 🟩 works, verified on the named card ·
🟨 same code path, untested on that platform · ⬜ not yet · — not offered by Intel either. Evidence per cell:
[docs/PLATFORMS.md](docs/PLATFORMS.md).

![Intel GPU platforms](docs/parity/svg/platforms.svg)

Code-level progress against Linux `xe` (measured, not estimated): [docs/parity](docs/parity/README.md);
its history: [docs/parity/HISTORY.md](docs/parity/HISTORY.md); next steps: [docs/ROADMAP.md](docs/ROADMAP.md).

![xe uAPI coverage](docs/parity/svg/uapi.svg)

## Building from source

| Path | Contents |
|---|---|
| `kernel/IntelXe/` | GPU kext and `build.py` (builds both kexts); `uapi/` |
| `kernel/IntelXeFB/` | display kext |
| `nullmoth/` | Metal plugin, translator, NMXAccel, NMXAGDC; `build/build-intelxe.sh` |
| `mesa/` | Mesa changes: `intelxe.diff` on upstream `f01e9b07a91` (`apply.sh`, `configure.sh`), and the same changes as a patch series |
| `user/` | `xemac` (user side of the uAPI), tests and tools |
| `videotoolbox/` | VideoToolbox decoder and encoders; `ffmpeg/` (patches and configure line of the shared FFmpeg libraries) |
| `release/` | the installer and install guide of the release packages (`templates/`, filled in by `package.sh`) |
| `firmware/` | `fetch.sh` for the GuC/HuC firmware |
| `efi/` | OpenCore notes and `SSDT-ARCOFF.dsl` |
| `docs/` | measurements (`devices/b580.md`), platform table, roadmap, licensing, design notes |

Order: `firmware/fetch.sh` → `kernel/IntelXe/build.py` (MacKernelSDK) → Mesa (`mesa/README.md`) →
`nullmoth/build/build-intelxe.sh` with `ANV_DYLIB` set → the codecs (`videotoolbox/README.md`). Each script states what
it needs at its top.

## Versioning

Releases follow [Semantic Versioning](https://semver.org) in its 0.x form until the driver is ready for daily use
(1.0.0): a new feature, a new macOS version or a new GPU raises the minor number (0.2.0); fixes alone raise the patch
number (0.1.1). A change that needs manual steps when updating (an EFI change, renamed boot-args) comes with upgrade
steps in the release notes. Packages, the GitHub tag and `install.sh` carry the release number; a kext or the Metal
driver carries the number of the release that last rebuilt it (0.1.1 changed only the guide, the docs and the
packaging; 0.1.2 rebuilt everything except `IntelXe.kext`, which still says 0.1.0).

## Philosophy

- **Faithful to Linux and Mesa.** The kernel driver follows Linux `xe` and i915 display (GuC ABI, LRC layouts,
  workarounds, SLPC, page tables, DP link training, C20 PHY); each function names the Linux code it comes from. Mesa's
  ANV runs essentially unchanged and talks to the kernel through the real xe uAPI.
- **Proper fixes, not workarounds.** A fix goes where Linux or Mesa would put it; stopgaps are listed and replaced.
- **Modular per GPU generation.** Hardware knowledge is organised by IP version, so later generations are modules,
  not conditionals.

## FAQ

**Is this an official Intel or Apple driver?** No. It is an independent project, not affiliated with Intel, Apple or
NullMoth Systems.

**Will my Arc A-series card, another B-series card or integrated graphics work?** Not yet. Only the B580 is supported;
the [status table](#project-status) shows how much of the code they share with it.

**Is it safe?** It changes how your Mac boots and runs with relaxed security. Keep a bootable USB EFI, and use
`./install.sh --undo` to go back.

**Why is it called IntelXe?** The driver targets Intel's Xe GPUs, like the Linux `xe` driver it follows. Earlier
private builds were called B580.

## Reporting a problem

Open an issue with the bug template. `tools/report/` collects the logs it asks for and removes serial numbers, UUIDs,
MAC addresses and user names first; please do not post raw system reports.

## Licence

- **Our code:** MIT (`LICENSE`).
- **PolyForm Noncommercial 1.0.0:** `nullmoth/` and `kernel/IntelXeFB/IntelXeFB.cpp`.
- **LGPL-3.0-or-later:** `nullmoth/translator/`.
- **GuC/HuC firmware:** Intel's `LICENSE.xe`; not in the repository (`firmware/fetch.sh` downloads it), built into
  `IntelXe.kext` in the release packages.

The repository and the release packages are for **noncommercial use**. Details: `docs/LICENSING.md` and `NOTICE`.

## Credits

- [nullmoth](https://github.com/nullmoth/nvidia-macos-driver) (NullMoth Systems): the Metal plugin, the AIR to SPIR-V
  translator and the accelerator kexts this stack is built on.
- [metal2vulkan](https://github.com/steelbrain/metal2vulkan) by Anees Iqbal: the translator nullmoth's is based on.
- Linux `xe` and i915 (Intel), which the kernel driver follows; [Mesa](https://mesa3d.org) ANV, the Vulkan driver.
- Emil J. Tywoniak ([widlarizer/mesa](https://github.com/widlarizer/mesa)): the Xe2 VDEnc work in `mesa/xe2-venc/`.
- FFmpeg: the Vulkan video code the VideoToolbox codecs use.

Intel, Arc, Apple, macOS and Metal are trademarks of their owners.
