#!/bin/bash
# SPDX-License-Identifier: MIT
# leakloop.sh [seconds=600]: vk_smoke, mtl_tests and (every 5th round) a 2 s wsitest window in a loop, with the B580
# counters sampled every 30 s into $INTELXE_HOME/rb1/leak-HHMMSS/ (snap-N.txt, run.log). Pauses while gpu_busy.sh says a
# game or benchmark runs. Non-hanging work only. Start it with nohup in the background; it ends by itself.
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
set -u
B=$INTELXE_HOME; T=${1:-600}
D=$B/rb1/leak-$(date +%H%M%S); mkdir -p "$D"; L=$D/run.log
end=$(( $(date +%s) + T )); next=0; k=0; round=0; ok=0; fail=0
snap() {
	{ echo "t $(date +%s) round $round ok $ok fail $fail"; sysctl -n debug.intelxe.stats; sysctl -n debug.intelxe.vram | head -2
	  sysctl -n debug.intelxe.surfvram_stats; ioclasscount IOAccelIntelXeClient IOBufferMemoryDescriptor IOGeneralMemoryDescriptor \
	  IOMemoryMap IOSubMemoryDescriptor IOMultiMemoryDescriptor IOSurface 2>/dev/null; vm_stat | grep -E "wired|free"
	} > "$D/snap-$k.txt" 2>&1
	k=$((k + 1))
}
echo "start $(date) for $T s" > "$L"
while [ "$(date +%s)" -lt "$end" ]; do
	now=$(date +%s)
	[ "$now" -ge "$next" ] && { snap; next=$((now + 30)); }
	if b=$("$B/wsitest/gpu_busy.sh"); then echo "$(date +%T) paused: $b" >> "$L"; sleep 5; continue; fi
	round=$((round + 1))
	if "$B/vk_smoke" /Library/GPUBundles/nvmtl/libvulkan_intel.dylib 1 > "$D/last-vk.txt" 2>&1 && grep -q "EXECUTED" "$D/last-vk.txt"; then
		ok=$((ok + 1)); else fail=$((fail + 1)); echo "$(date +%T) round $round vk_smoke FAILED" >> "$L"; cp "$D/last-vk.txt" "$D/fail-vk-$round.txt"; fi
	if "$B/mtl_tests" > "$D/last-mtl.txt" 2>&1 && grep -q "ALL PASSED" "$D/last-mtl.txt"; then
		ok=$((ok + 1)); else fail=$((fail + 1)); echo "$(date +%T) round $round mtl_tests FAILED" >> "$L"; cp "$D/last-mtl.txt" "$D/fail-mtl-$round.txt"; fi
	if [ $((round % 5)) -eq 0 ]; then
		if "$B/wsitest/run_wsitest.sh" immediate 2 3 > "$D/last-wsi.txt" 2>&1 && grep -q "^done" "$D/last-wsi.txt"; then
			ok=$((ok + 1)); else fail=$((fail + 1)); echo "$(date +%T) round $round wsitest FAILED" >> "$L"; cp "$D/last-wsi.txt" "$D/fail-wsi-$round.txt"; fi
	fi
done
snap
echo "end $(date): rounds $round ok $ok fail $fail" >> "$L"
