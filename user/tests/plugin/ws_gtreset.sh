#!/bin/bash
# SPDX-License-Identifier: MIT
# ws_gtreset.sh [attempts]: AFTER install.sh and a new login - proof that WindowServer survives a ban of its OWN queue.
# WindowServer is kept busy by a full-rate Vulkan window (wsitest.app, IMMEDIATE present: one composite per refresh);
# then debug.intelxe.gt_reset=1 (root) resets the GT, which bans every queue with a job running at that moment. When
# WindowServer's queue is among them (IntelXe g2h log "GT reset: queue guc_id N of WindowServer ... was running ...: banned"),
# its plugin must log "GPU RECOVERY #k in WindowServer" and WindowServer must keep its pid. Attempts that miss
# WindowServer cost it nothing; one that hits costs one of its 3 recoveries per minute, so the loop stops at the first
# hit and attempts are >= 8 s apart. Time-boxed to ~50 s (default 5 attempts). Needs sudo -n.
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
set -u
A=${1:-5}
L=/tmp/nvmtl.log
WS=$(pgrep -x WindowServer) || { echo "no WindowServer"; exit 1; }
grep -q "pid $WS NVMTL: vk: GPU reset recovery ON" $L || { echo "WindowServer $WS does not run the recovery plugin + Mesa (install.sh, then log out and in)"; exit 1; }
if "$INTELXE_HOME/wsitest/gpu_busy.sh"; then echo "ABORT: GPU busy"; exit 9; fi
sudo -n true 2>/dev/null || { echo "needs sudo -n"; exit 1; }
s() { sysctl -n debug.intelxe.stats | grep -E "^jobs|^TDR"; }
hits() { sudo -n sysctl -n debug.intelxe.g2h | grep -c "GT reset: queue guc_id [0-9]* of WindowServer (pid $WS,"; }
echo "== before (WindowServer pid $WS)"; s
r0=$(grep -c "pid $WS NVMTL: vk: GPU RECOVERY #" $L); h0=$(hits); M=$(mktemp /tmp/ws_gtreset.XXXXXX)
open -n "$INTELXE_HOME/wsitest/wsitest.app" --args --icd /Library/GPUBundles/nvmtl/intel_icd.json --mode immediate --seconds 45 --images 3 --out /tmp/wsitest-gtreset.txt
sleep 3
hit=0
for i in $(seq 1 "$A"); do
    sudo -n sysctl debug.intelxe.gt_reset=1 > /dev/null || { echo "gt_reset write failed"; break; }
    sleep 2
    if [ "$(hits)" -gt "$h0" ]; then hit=1; echo "attempt $i: WindowServer's queue was running and is banned"; break; fi
    echo "attempt $i: WindowServer had no job running at the reset (no cost to it)"; sleep 6
done
sleep 2; pkill -x wsitest 2>/dev/null
echo "== after"; s
echo "== IntelXe g2h (GT reset lines)"; sudo -n sysctl -n debug.intelxe.g2h | grep "GT reset" | tail -8
echo "== WindowServer plugin log"; grep "pid $WS NVMTL: vk: \(GPU RECOVERY\|GPU recovery\|a command buffer in flight\|.*submitted again\|.*disabling backend\|command buffer refused\)" $L | tail -8 | cut -c1-260
r1=$(grep -c "pid $WS NVMTL: vk: GPU RECOVERY #" $L)
ws=$(pgrep -x WindowServer)
new=$(find /Library/Logs/DiagnosticReports -name 'WindowServer*' -newer "$M" 2>/dev/null | wc -l | tr -d ' '); rm -f "$M"
echo "WindowServer now pid ${ws:-NONE} (was $WS); recoveries in it $r0 -> $r1; new WindowServer crash reports $new; console user $(stat -f %Su /dev/console)"
if [ "$ws" = "$WS" ] && [ "$new" = 0 ] && grep -q "pid $WS NVMTL: vk: \(GPU RECOVERY REFUSED\|GPU RECOVERY FAILED\)" $L; then echo "RESULT: FAIL - recovery refused or failed"; exit 1; fi
if [ "$ws" != "$WS" ] || [ "$new" != 0 ]; then echo "RESULT: FAIL - WindowServer restarted"; exit 1; fi
if [ $hit = 1 ] && [ "$r1" -gt "$r0" ]; then echo "RESULT: PASS - WindowServer's own queue was banned, it recovered and kept running"; exit 0; fi
if [ $hit = 1 ]; then echo "RESULT: UNCLEAR - banned, but no GPU RECOVERY line yet (WindowServer submits again at its next frame: move the mouse, re-check $L)"; exit 2; fi
echo "RESULT: NOT HIT - no reset caught WindowServer running; run again in >= 10 s"; exit 3
