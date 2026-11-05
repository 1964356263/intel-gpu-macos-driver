#!/bin/bash
# SPDX-License-Identifier: MIT
# svqa.sh <test> [seconds]: surfvram=3 default QA (DESIGN-iosurface-vram.md §11), short automated checks, each under
# 60 s. Every test prints the counters that matter before/after (surfvram copy failures/timeouts, page-offs, dirty
# failures; NMXAccel p4 page-offs/failed/busy and flips), the WindowServer pid (must not change) and takes a picture:
# screencapture if this session may (over ssh TCC often refuses it), else the kernel's scan-out thumbnail
# (debug.intelxefb_thumb, 320x180 PPM). Pictures: $INTELXE_HOME/rb6c/svqa/<test>-<time>.{jpg,ppm}
#   base           counters + picture only
#   record [N]     screencapture -v -V N (default 8 s) video recording (ScreenCaptureKit); one frame extracted with
#                  ffmpeg to a jpg. Expect p4 page-offs to grow by about one per captured frame, failures 0
#   expose         Mission Control on (open -a "Mission Control"), 3 s, off again: window thumbnails composited
#   flip0 [N]      copy-instead-of-flip for N s (debug.nmxaccel_flip=0, then back to 1; §11 item 5): frames are
#                  copied, and must be current (pictures during and after)
#   watch [N]      samples the counters every 2 s for N s (default 50) while the user does something by hand
#                  (Screen Sharing/VNC session, QuickTime recording, Dock/genie, Mission Control, display settings)
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
set -u
T=${1:-base}; N=${2:-}; O=$INTELXE_HOME/rb6c/svqa; mkdir -p "$O"; TS=$(date +%H%M%S)
if [ "$T" != base ] && [ "$T" != watch ]; then
	if b=$("$INTELXE_HOME/wsitest/gpu_busy.sh"); then echo "ABORT: $b"; exit 9; fi
fi
k() { sysctl -n "$1" 2>/dev/null; }
counters() {
	local s; s=$(sysctl -n debug.intelxe.surfvram_stats | head -1)
	echo "surfvram $(echo "$s" | grep -oE '^surfvram [0-9]+|[0-9]+ backings|page-offs [0-9]+|page-ons [0-9]+|dirty [0-9]+ \(failed [0-9]+\)|copy failures [0-9]+ \(timeouts [0-9]+\)' | tr '\n' ';')"
	echo "nmx p4 pageoffs $(k debug.nmxaccel_p4_pageoffs) failed $(k debug.nmxaccel_p4_failed) busy $(k debug.nmxaccel_p4_busy); flips $(k debug.nmxaccel_flips) refused $(k debug.nmxaccel_flip_refused) late $(k debug.nmxaccel_flip_late) l2fail $(k debug.nmxaccel_flip_l2fail); copies $(k debug.nmxaccel_scanout_copies)"
	echo "WindowServer $(pgrep -x WindowServer); intelxe bans $(sysctl -n debug.intelxe.stats | sed -n 's/.* bans \([0-9]*\).*/\1/p' | head -1)"
}
picture() {   # $1 tag
	local f="$O/$T-$TS-$1"
	if /usr/sbin/screencapture -x -t jpg "$f.jpg" 2>/dev/null && [ -s "$f.jpg" ]; then echo "picture $f.jpg"
	elif sudo -n "$INTELXE_HOME/thumb" "$f.ppm" 2>/dev/null && [ -s "$f.ppm" ]; then echo "picture $f.ppm (scan-out thumbnail; screencapture refused here)"
	else echo "picture: none (screencapture refused, thumb needs root)"; fi
}
WS0=$(pgrep -x WindowServer); echo "== $T $(date +%T) before"; counters
case $T in
base) picture now ;;
record) S=${N:-8}; M="$O/record-$TS.mov"
	/usr/sbin/screencapture -x -v -V "$S" "$M" > "$O/record-$TS.log" 2>&1; rc=$?
	echo "screencapture -v rc $rc, $(stat -f %z "$M" 2>/dev/null || echo 0) bytes; $(head -2 "$O/record-$TS.log")"
	[ -s "$M" ] && "$INTELXE_HOME/video/ffmpeg" -nostdin -loglevel error -ss 2 -i "$M" -frames:v 1 -y "$O/record-$TS-frame.jpg" && echo "frame $O/record-$TS-frame.jpg" ;;
expose) open -a "Mission Control"; sleep 3; picture expose; open -a "Mission Control"; sleep 2; picture after ;;
flip0) S=${N:-10}
	sudo -n sysctl -w debug.nmxaccel_flip=0 >/dev/null || { echo "need root for debug.nmxaccel_flip"; exit 1; }
	sleep $((S / 2)); picture copying; sleep $((S - S / 2))
	sudo -n sysctl -w debug.nmxaccel_flip=1 >/dev/null; echo "flip back to $(k debug.nmxaccel_flip)"; sleep 2; picture after ;;
watch) S=${N:-50}
	for i in $(seq 1 $((S / 2))); do echo "$(date +%T) $(counters | tr '\n' ' ')"; sleep 2; done; picture end ;;
*) echo "usage: $0 base|record [s]|expose|flip0 [s]|watch [s]"; exit 1 ;;
esac
WS1=$(pgrep -x WindowServer); echo "== after"; counters
[ "$WS0" != "$WS1" ] && echo "WINDOWSERVER CHANGED ($WS0 -> $WS1)"
