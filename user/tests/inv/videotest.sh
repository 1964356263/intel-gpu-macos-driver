# SPDX-License-Identifier: MIT
# videotest.sh <libvulkan_intel.dylib>: Vulkan Video on the B580 with the given ANV: capabilities (no ANV_DEBUG), ffmpeg
# Vulkan decode bit-exactness against ffmpeg's software decoders on ~/b580/video, HEVC Vulkan encode speed and PSNR.
busy() { pgrep -x java >/dev/null || pgrep -f geekbench >/dev/null || pgrep -f Geekbench >/dev/null; }
if busy; then echo "BUSY - aborted"; exit 1; fi
ANV=${1:?anv lib}
FF=~/b580/video/ffmpeg; SHIM=~/b580/vkshim; mkdir -p $SHIM; cp -f ~/b580/video/libvulkan.dylib $SHIM/;  # only the shim: DYLD_LIBRARY_PATH would also replace INTELXE_ANV by a libvulkan_intel.dylib beside it
 CAPS=~/b580/venc/vk_videocaps
echo "ffmpeg $FF | vkshim $SHIM | videocaps $CAPS | debug.intelxe.video=$(sysctl -n debug.intelxe.video)"
[ "$(sysctl -n debug.intelxe.video)" = 1 ] || { echo "media GT off (debug.intelxe.video=0) - not switched on here"; exit 2; }
echo "== capabilities"; "$CAPS" "$ANV" 2>&1 | head -60
run() { INTELXE_ANV=$ANV DYLD_LIBRARY_PATH=$SHIM "$FF" -hide_banner -loglevel error "$@"; }
echo "== decode (framemd5 against software)"
for f in ~/b580/video/*.mp4; do
  if busy; then echo "BUSY - aborted"; exit 1; fi
  sw=$("$FF" -hide_banner -loglevel error -i "$f" -an -vf format=nv12 -f framemd5 - 2>/dev/null | grep -v '^#' | awk -F, '{print $6}')
  hw=$(run -hwaccel vulkan -hwaccel_output_format vulkan -i "$f" -an -vf hwdownload,format=nv12 -f framemd5 - 2>/tmp/vt.err | grep -v '^#' | awk -F, '{print $6}')
  [ -z "$hw" ] && hw=$(run -hwaccel vulkan -hwaccel_output_format vulkan -i "$f" -an -vf hwdownload,format=p010le -f framemd5 - 2>>/tmp/vt.err | grep -v '^#' | awk -F, '{print $6}')
  nh=$(echo "$hw" | grep -c .)
  n=$(echo "$sw" | grep -c .); same=$(paste <(echo "$sw") <(echo "$hw") | awk '$1==$2' | grep -c .)
  [ "$n" = 0 ] && { echo "$(basename "$f"): $nh frames decoded on the GPU; no software decoder in this ffmpeg to compare with"; continue; }
  echo "$(basename "$f"): $same / $n frames bit-exact ($nh decoded on the GPU) $( [ "$same" = "$n" ] && [ "$n" -gt 0 ] && echo PASS || { echo FAIL; head -c 300 /tmp/vt.err; } )"
done
echo "== HEVC encode (hevc_vulkan, 1080p, 8 Mbit/s)"
src=~/b580/video/h264_1080.mp4
TIMEFORMAT='%R'
t=$( { time run -i "$src" -an -frames:v 300 -init_hw_device vulkan=vk -filter_hw_device vk -vf format=nv12,hwupload -c:v hevc_vulkan -b:v 8M -y /tmp/vt-enc.mp4; } 2>&1 | tail -1 )
echo "encode: 300 frames in ${t}s"
"$FF" -hide_banner -i /tmp/vt-enc.mp4 -i "$src" -frames:v 300 -lavfi "[0:v][1:v]psnr" -f null - 2>&1 | grep -o "PSNR.*" | tail -1
