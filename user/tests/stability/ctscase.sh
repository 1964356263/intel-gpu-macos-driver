#!/bin/bash
# SPDX-License-Identifier: MIT
# ctscase.sh [case]: one deqp-vk case on the B580 with the kernel's view of it, under 60 s (killed after 40 s).
# Default case: the r8g8b8_srgb multi-layer clear that came back DEVICE_LOST. In the G2H log:
#   "CONTEXT_RESET for guc_id N" (+ rb4: "guc_id N reset by the GuC: deqp-vk") = a GPU hang the GuC reset (the batch)
#   "MEMORY_CAT_ERROR for guc_id N (type)"                              = a translation fault (an address problem)
#   "job timeout: ..."                                                   = the watchdog (no reset by the GuC)
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
set -u
CASE=${1:-dEQP-VK.api.image_clearing.core.clear_color_image.2d.optimal.multiple_layers.r8g8b8_srgb_33x128_multiple_subresourcerange}
B=$HOME/vk-cts; Q=/tmp/ctscase.qpa
if b=$("$INTELXE_HOME/wsitest/gpu_busy.sh"); then echo "ABORT: $b"; exit 9; fi
pgrep -l deqp-vk && { echo "ABORT: deqp-vk already running"; exit 9; }
c() { sysctl -n debug.intelxe.stats | grep -E "^jobs|^TDR"; }
WS0=$(pgrep -x WindowServer); echo "== $(date +%T) $CASE"; c
cd "$B" && rm -f $Q && "$B/deqp-vk" --deqp-case="$CASE" --deqp-log-filename=$Q --deqp-vk-library-path=/usr/local/lib/libvulkan.1.dylib \
	--deqp-archive-dir="$B" --deqp-log-images=disable --deqp-log-shader-sources=disable > /tmp/ctscase.out 2>&1 & P=$!
for i in $(seq 1 40); do kill -0 $P 2>/dev/null || break; sleep 1; done
kill -0 $P 2>/dev/null && { echo "still running after 40 s: killed"; kill -9 $P; }
echo "== result: $(grep -o 'StatusCode="[A-Za-z]*"' $Q 2>/dev/null | tail -1) $(grep -o '<Result StatusCode="[A-Za-z]*">[^<]*' $Q 2>/dev/null | tail -1)"
tail -3 /tmp/ctscase.out
WS1=$(pgrep -x WindowServer); echo "== after: WindowServer $WS0 -> $WS1"; c
echo "== G2H log (last 10)"; sudo -n sysctl -n debug.intelxe.g2h 2>/dev/null | tail -10
