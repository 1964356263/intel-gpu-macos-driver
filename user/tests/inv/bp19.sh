# SPDX-License-Identifier: MIT
cd ~/b580
export NVMTL_ENABLE=1 NVMTL_ICD_LIB=$HOME/b580/prof/mesa-rel/libvulkan_intel.dylib
for B in fix18 fix19; do
  export NVMTL_BUNDLE=$HOME/b580/$B/NVMTLDriver.bundle
  echo "== $B"
  echo "cpu reader at completion: $(inv/burstpresent frames 200 seed 7 2>&1 | tail -1)"
  echo "gpu reader at completion: $(inv/burstpresent frames 200 gpu seed 7 2>&1 | tail -1)"
  echo "gpu reader at scheduled:  $(inv/burstpresent frames 200 gpu sched seed 7 2>&1 | grep -v 'implemented in both' | tail -4 | tr '\n' '|')"
  echo "cpu reader at scheduled:  $(inv/burstpresent frames 200 sched seed 7 2>&1 | grep -v 'implemented in both' | tail -3 | tr '\n' '|')"
  echo "gpu sched, SCHEDULE_AFTER_SURFACE_WRITES=1: $(NVMTL_SCHEDULE_AFTER_SURFACE_WRITES=1 inv/burstpresent frames 200 gpu sched seed 7 2>&1 | tail -2 | tr '\n' '|')"
done
