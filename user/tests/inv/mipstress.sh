# SPDX-License-Identifier: MIT
# mipstress.sh [rounds] [bundle]: the mip variants in the gate's order (0..13), round after round in one process, with
# GPU load from another process (burstpresent) as during a gate; prints every failing variant with its round.
busy() { pgrep -x java >/dev/null || pgrep -f geekbench >/dev/null || pgrep -f Geekbench >/dev/null; }
if busy; then echo "BUSY - aborted"; exit 1; fi
R=${1:-50}; B=${2:-}
cd ~/b580
export NVMTL_ENABLE=1 NVMTL_ICD_LIB=$HOME/b580/mesa-rel-pkg-fix20/libvulkan_intel.dylib
[ -n "$B" ] && export NVMTL_BUNDLE=$B || unset NVMTL_BUNDLE
inv/burstpresent frames 100000 gpu sched seed 3 > /tmp/mipstress-load.out 2>&1 & L=$!
MIP_ONLY=0,1,2,3,4,5,6,7,8,9,10,11,12,13 MIP_REPEAT=$R inv/mtl_tests_np mip > /tmp/mipstress.out 2>&1
kill $L 2>/dev/null
echo "mip stress: $R rounds x 14 variants, $(grep -c 'PASS mip' /tmp/mipstress.out) passed, $(grep -c 'FAIL mip' /tmp/mipstress.out) failed"
grep -n "FAIL mip" /tmp/mipstress.out | head -10
