#!/bin/sh
# SPDX-License-Identifier: MIT
# build.sh: the IntelXe AV1 VideoToolbox decoder against FFmpeg's shared libraries (FFmpeg 9.0.2 + ffmpeg/apply-patches.sh, LGPL-2.1-or-later,
# configured by ffmpeg/configure-shared.sh with install names in /Library/GPUBundles/nvmtl).
#   FFMPEG_INSTALL=<ffmpeg install prefix> MESA_INCLUDE=<mesa>/include [OUT=dir] [ANV=<path of libvulkan_intel.dylib>] build.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/build}
: "${FFMPEG_INSTALL:?}" "${MESA_INCLUDE:?}"
SDK=${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
mkdir -p "$OUT"
DEF=""; [ -n "${ANV:-}" ] && DEF="-DINTELXE_ANV=\"$ANV\""
xcrun --sdk "$SDK" clang -isysroot "$SDK" -arch x86_64 -mmacosx-version-min=15.0 -O2 -g -Wall -Wno-deprecated-declarations \
  -fvisibility=hidden $DEF -I"$FFMPEG_INSTALL/include" -I"$MESA_INCLUDE" -dynamiclib \
  -install_name /Library/GPUBundles/nvmtl/libintelxeav1dec.dylib -o "$OUT/libintelxeav1dec.dylib" "$HERE/intelxeav1.c" \
  -L"$FFMPEG_INSTALL/lib" -lavcodec -lavutil \
  -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework IOSurface
cp -p "$FFMPEG_INSTALL/lib/libavcodec.63.dylib" "$FFMPEG_INSTALL/lib/libavutil.61.dylib" "$OUT/" 2>/dev/null || {
  cp -pL "$FFMPEG_INSTALL/lib/libavcodec.63.dylib" "$OUT/libavcodec.63.dylib"; cp -pL "$FFMPEG_INSTALL/lib/libavutil.61.dylib" "$OUT/libavutil.61.dylib"; }
# the debug map (source and object paths of this machine) stays in the .dSYM next to it, not in the shipped library
strip -S "$OUT/libintelxeav1dec.dylib"
for f in libintelxeav1dec.dylib libavcodec.63.dylib libavutil.61.dylib; do codesign -f -s - "$OUT/$f"; done
