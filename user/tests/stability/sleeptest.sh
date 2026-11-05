#!/bin/bash
# SPDX-License-Identifier: MIT
# sleeptest.sh (v2, rb6b+): system sleep/wake on an idle desktop. Each step under 60 s. Run in this order:
#   pre        state before: counters, VRAM, WindowServer, power settings, screenshot /tmp/sleep-pre.jpg, and the engine
#              registers that must survive (step 20 reads, render forcewake from rb6: RCS RING_CMD_CCTL 0x20c4 = 0x306,
#              HALF_SLICE_CHICKEN7 0xe194 bit 6, RCU_MODE 0x14800 bit 0, RCS GFX_MODE 0x229c bit 3)
#   video-on   optional: a looping hardware H.264 decode in the background (media queue alive across the sleep: rb4
#              registers media queues again at resume instead of banning them); log /tmp/sleep-video.txt
#   go N       RTC wake in N minutes (default 5; WEX-era sleep entry took up to ~2 min), sleep 3 s later; returns at once
#   post       after wake: the B580 report (resume, both ADS save/restore lists, media GuC/HuC), sleep/wake log, counters,
#              WindowServer pid, screenshot /tmp/sleep-post.jpg, the same registers, the decode (still running, frames
#              advancing, no error), vk_smoke and mtl_tests; kernel log to $INTELXE_HOME/rb6c/sleep/kernel.txt in the background
#   video-off  stop the background decode
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
set -u
S=${1:-pre}; O=$INTELXE_HOME/rb6c/sleep; mkdir -p "$O"
V=$INTELXE_HOME/video
ANV=/Library/GPUBundles/nvmtl/libvulkan_intel.dylib; [ -f "$ANV" ] || ANV=$V/libvulkan_intel.dylib
snap() {
	echo "date $(date) waketime $(sysctl -n kern.waketime 2>/dev/null) sleeptime $(sysctl -n kern.sleeptime 2>/dev/null)"
	echo "WindowServer $(pgrep -x WindowServer) loginwindow $(pgrep -x loginwindow) console user $(stat -f %Su /dev/console)"
	sysctl -n debug.intelxe.stats; sysctl -n debug.intelxe.vram | head -2; sysctl -n debug.intelxe.surfvram_stats
}
regs() {   # step 20 rewrites debug.intelxe.state: read the report first
	for a in 0x20c4 0xe194 0x14800 0x229c; do
		sudo -n sysctl -w debug.intelxe.mmio_addr=$((a)) >/dev/null && sudo -n sysctl -w debug.intelxe.step=20 >/dev/null &&
			echo "reg $(sysctl -n debug.intelxe.state | tail -1)"
	done
	echo "expected: 0x20c4 = 0x00000306, 0xe194 bit 6 (0x40), 0x14800 bit 0, 0x229c bit 3 (0x8) -- the 'with forcewake' value"
}
vframes() { tr '\r' '\n' < /tmp/sleep-video.txt 2>/dev/null | grep -o 'frame= *[0-9]*' | tail -1 | tr -dc 0-9; }
case $S in
pre)  { snap; pmset -g; pmset -g sched; pmset -g assertions | head -30; } > "$O/pre.txt" 2>&1
      /usr/sbin/screencapture -x -t jpg /tmp/sleep-pre.jpg 2>/dev/null
      sudo -n true 2>/dev/null && echo "sudo ok" || echo "sudo NEEDS A PASSWORD (pmset schedule/sleepnow and the register reads need root)"
      grep -E "^date|^WindowServer|sleep |displaysleep|womp|darkwakes|standby|hibernatemode|autopoweroff|powernap|tcpkeepalive" "$O/pre.txt"
      regs | tee "$O/regs-pre.txt" ;;
video-on)
      pgrep -f "sleep-video-loop" >/dev/null && { echo "already running"; exit 0; }
      cd "$V" && nohup env INTELXE_ANV="$ANV" DYLD_LIBRARY_PATH="$V" ./ffmpeg -nostdin -hide_banner -stream_loop -1 -re \
          -init_hw_device vulkan=vk:0 -hwaccel vulkan -hwaccel_output_format vulkan -i h264_1080.mp4 \
          -metadata comment=sleep-video-loop -f null - > /tmp/sleep-video.txt 2>&1 &
      sleep 5; echo "decode pid $(pgrep -f sleep-video-loop | head -1), frames $(vframes) after 5 s (real time: ~150 expected)" ;;
go)   M=${2:-5}; W=$(date -v+${M}M "+%m/%d/%y %H:%M:%S")
      sudo -n pmset schedule wake "$W" && echo "RTC wake scheduled for $W" || { echo "schedule failed"; exit 1; }
      pmset -g sched | tail -3
      [ -f /tmp/sleep-video.txt ] && echo "decode frames before sleep: $(vframes)" > "$O/video-before.txt"
      nohup sh -c 'sleep 3; sudo -n pmset sleepnow' > "$O/sleepnow.txt" 2>&1 &
      echo "sleeping in 3 s ($(date +%T))" ;;
post) sysctl -n debug.intelxe.state > "$O/state-post.txt" 2>&1
      { snap; pmset -g log | grep -E " Sleep | Wake | DarkWake |Wake Requests|Failure" | tail -20; } > "$O/post.txt" 2>&1
      /usr/sbin/screencapture -x -t jpg /tmp/sleep-post.jpg 2>/dev/null
      head -40 "$O/post.txt"
      echo "== IntelXe report"; grep -E "resume|suspend|ADS register|media GuC|HuC|forcewake|wedged|GT reset" "$O/state-post.txt" | tail -20
      echo "== registers"; regs | tee "$O/regs-post.txt"
      if pgrep -f sleep-video-loop >/dev/null; then
          f1=$(vframes); sleep 4; f2=$(vframes)
          echo "== decode: alive, frames $f1 -> $f2 in 4 s ($(cat "$O/video-before.txt" 2>/dev/null)); errors: $(grep -ciE 'error|lost|fail' /tmp/sleep-video.txt)"
      elif [ -f /tmp/sleep-video.txt ]; then echo "== decode: NOT running any more; last lines:"; tail -5 /tmp/sleep-video.txt; fi
      nohup sh -c "log show --last 20m --style compact --predicate 'process == \"kernel\" AND (eventMessage CONTAINS \"IntelXe\" OR eventMessage CONTAINS \"intelxe\" OR eventMessage CONTAINS \"suspend\" OR eventMessage CONTAINS \"resume\" OR eventMessage CONTAINS \"NMX\")' > $O/kernel.txt 2>&1" > /dev/null 2>&1 &
      if b=$("$INTELXE_HOME/wsitest/gpu_busy.sh"); then echo "GPU tests skipped: $b"; exit 0; fi
      "$INTELXE_HOME/vk_smoke" /Library/GPUBundles/nvmtl/libvulkan_intel.dylib 1 2>&1 | tail -1
      "$INTELXE_HOME/mtl_tests" 2>&1 | tail -1 ;;
video-off) pkill -f sleep-video-loop && echo "decode stopped" || echo "no decode running"; tail -2 /tmp/sleep-video.txt ;;
*) echo "usage: $0 pre|video-on|go [minutes]|post|video-off"; exit 1 ;;
esac
