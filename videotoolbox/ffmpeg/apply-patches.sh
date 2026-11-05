#!/bin/sh
# SPDX-License-Identifier: MIT
# apply-patches.sh <ffmpeg-9.0.2 source>: the FFmpeg patches of the released libavcodec/libavutil, in the order they were
# applied, to an unpacked https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
# (sha256 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e). Then configure-shared.sh.
#
# Checked 2026-11-05: these eight patches + configure-shared.sh rebuild the installed libavcodec.63.dylib (714e989a) and
# libavutil.61.dylib (1682f7ab) with identical code and data; every byte matches except LC_UUID, which ld64 derives from
# the link before `make install` strips the debug map (object file paths of the build directory). That build was
# configured with the paths of its build machine, which its avcodec_configuration() string names; the release
# libraries are configured with relative paths (PREFIX=install, MESA_INCLUDE=vk-include: a copy of <mesa>/include in
# the build directory), which changes only that string.
#
# Not applied: ffmpeg-9.0.2-vulkan-encode-consecutive-b-frames.patch (the AV1/HEVC half of -all, which supersedes it)
# and ffmpeg-vulkan-encode-av1-enable-cdef-under-rc.OPTIONAL.patch (the same file as the non-OPTIONAL one, applied).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
cd "${1:?usage: apply-patches.sh <ffmpeg-9.0.2 source>}"
for p in \
    ffmpeg-9.0.2-vulkan-decode-free-a-picture-without-a-host-wait \
    ffmpeg-9.0.2-vulkan-one-queue-per-decode-session-fixed-exec-depth \
    ffmpeg-9.0.2-vulkan-encode-consecutive-b-frames-all \
    ffmpeg-9.0.2-vulkan-encode-dyadic-reference-pattern \
    ffmpeg-9.0.2-vulkan-encode-multiref-h264-pyramid-av1-pyramid \
    ffmpeg-vulkan-encode-av1-enable-cdef-under-rc \
    ffmpeg-9.0.2-vp9-release-the-hwaccel-picture-first \
    ffmpeg-9.0.2-vulkan-exec-frame-deps-keep-the-frames-context; do
  patch -p1 --forward --no-backup-if-mismatch -s < "$HERE/$p.patch"
  echo "applied $p"
done
