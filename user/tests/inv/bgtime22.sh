# SPDX-License-Identifier: MIT
busy() { pgrep -x java >/dev/null || pgrep -f geekbench >/dev/null || pgrep -f Geekbench >/dev/null; }
if busy; then echo "BUSY - aborted"; exit 1; fi
cd ~/b580
export NVMTL_ENABLE=1 NVMTL_ICD_LIB=$HOME/b580/mesa-rel-pkg-fix20/libvulkan_intel.dylib NVMTL_BUNDLE=$HOME/b580/fix22/NVMTLDriver.bundle
TIMEFORMAT='%R'
for round in 1 2 3; do for bg in 0 1; do
  if busy; then echo "BUSY - aborted"; exit 1; fi
  rm -rf /tmp/xb22; mkdir -p /tmp/xb22/aircache
  t=$( { time NVMTL_AIRCACHE=/tmp/xb22/aircache NVMTL_BG_XLATE=$bg ./mtl_tests > /tmp/xb22.out 2>&1; } 2>&1 )
  echo "round $round bg=$bg: ${t}s | $(tail -1 /tmp/xb22.out) | spv $(ls /tmp/xb22/spvcache 2>/dev/null | wc -l | tr -d ' ')"
done; done
grep -h "translate (background)" $TMPDIR/nvmtl.log | tail -2 | cut -c1-220
