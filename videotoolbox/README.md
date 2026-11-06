# VideoToolbox codecs on the B580

VideoToolbox decoder and encoder plug-ins that run on the B580's media engines through Vulkan Video (Mesa ANV from
`/Library/GPUBundles/nvmtl/`), with libavcodec doing the bitstream and reference bookkeeping. FFmpeg 9.0.2 with the
patches in `ffmpeg/` (Vulkan decode and encode fixes) is used as shared libraries next to the plug-ins.

- **Decoders** (`intelxeav1.c`, `libintelxeav1dec.dylib`; the file name is historical): AV1 (`av01`) and VP9, and H.264
  (High and below, 8-bit) and HEVC (Main, Main10) as the hardware decoder of last resort when the system has none for
  them; NV12/P010 IOSurface pixel buffers, full or video range as the stream is ('420f'/'xf20' or '420v'/'x420').
- **Encoders** (`encoder/intelxevenc.c`, `libintelxevenc.dylib`): HEVC (Main, Main10), H.264 (High) and AV1 (Main) on VDEnc,
  with libavcodec's `hevc_vulkan`, `h264_vulkan` and `av1_vulkan` (H.264 and AV1 encode on Xe2 need `mesa/patches/0010`,
  `0012`, `0015`).

**How they are registered (2026-10-29, the same on macOS 26):** macOS 15 and later drop third-party codec bundles in `/Library/Video/Plug-Ins` unless
they are Apple-signed, so the Metal plugin registers both libraries in-process (`VTRegisterVideoDecoderWithInfo` /
`VTRegisterVideoEncoderWithInfo`, plugin fix28) in every process that loads it, VTDecoderXPCService included. Installed
files: `/Library/GPUBundles/nvmtl/libintelxeav1dec.dylib`, `libintelxevenc.dylib`, `libavcodec.63.dylib`, `libavutil.61.dylib`.

## Files

| File | What |
|---|---|
| `intelxeav1.c`, `vtplugin.h` | the decoders (AV1, VP9, H.264, HEVC); the VideoToolbox decoder plug-in ABI (not in the public SDK: the CoreMedia derived-object layouts on macOS x86_64) |
| `build.sh` | builds `libintelxeav1dec.dylib` against the shared FFmpeg and copies `libavcodec.63`/`libavutil.61` next to it, all ad-hoc signed |
| `encoder/intelxevenc.c`, `encoder/vtencplugin.h` | the encoders; the encoder plug-in ABI (checked against Apple's x86_64 encoders) |
| `encoder/build.sh`, `encoder/vtenctest.m` | builds `libintelxevenc.dylib`; `vtenctest` drives a `VTCompressionSession` the way OBS/HandBrake/ffmpeg do |
| `ffmpeg/apply-patches.sh`, `ffmpeg/*.patch` | our FFmpeg 9.0.2 patches and the eight of them the released libraries carry, in order (two files there are not applied: see the script) |
| `ffmpeg/configure-shared.sh` | the FFmpeg 9.0.2 configuration: shared, LGPL only, AV1/H.264/HEVC/VP9 decoders + Vulkan hwaccels, Vulkan encoders |
| `tests/vtdec.m`, `tests/vtq.m`, `tests/sbprobe.c` | decode through `VTDecompressionSession`; what VideoToolbox offers; what a sandboxed video service can reach |
| `tests/vcbench.m` | decode throughput the way Video Codec Test measures it (parallel sessions, its pixel formats), and hardware vs software checksums |

## Building

```sh
videotoolbox/ffmpeg/apply-patches.sh <ffmpeg-9.0.2>          # the released set, in order
mkdir ffbuild && cd ffbuild && cp -R <mesa>/include vk-include  # relative paths: avcodec_configuration() names none
FFMPEG_SRC=<ffmpeg-9.0.2> MESA_INCLUDE=vk-include PREFIX=install ../videotoolbox/ffmpeg/configure-shared.sh && make -j8 && make install
FFMPEG_INSTALL=$PWD/install MESA_INCLUDE=<mesa>/include ../videotoolbox/build.sh
FFMPEG_INSTALL=$PWD/install MESA_INCLUDE=<mesa>/include ../videotoolbox/encoder/build.sh
```

## Licensing: FFmpeg

- FFmpeg is LGPL-2.1-or-later. It is modified (`ffmpeg/apply-patches.sh` lists the patches) and linked dynamically:
  `libavcodec.63.dylib` and `libavutil.61.dylib` are separate files that can be replaced by the user's own build of the
  same version and configuration. Anyone who receives those binaries must also be offered the corresponding FFmpeg
  9.0.2 source, the patches and the configure line (`ffmpeg/configure-shared.sh`).
- The plug-ins' own code (`intelxeav1.c`, `vtplugin.h`, `encoder/`, scripts, tests) is MIT.
- Earlier prototypes linked a patched FFmpeg statically (in the development history, not in this repository); that is no longer the case.
