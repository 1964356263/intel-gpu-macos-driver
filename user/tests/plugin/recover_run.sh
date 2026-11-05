#!/bin/bash
# SPDX-License-Identifier: MIT
# recover_run.sh <--fake|--fsubmit|--hang> [mtl_recover args]: one in-process GPU recovery test of the STAGED plugin
# (./NVMTLDriver.bundle) on the STAGED Mesa (./libvulkan_intel.dylib) next to this script; B580 counters before and after.
# Never touches WindowServer or installed files. Time-boxed to 50 s. Aborts when a game or benchmark runs.
#   NVMTL_ICD_LIB=installed  run on the installed Mesa instead (no recovery entry point: the old behaviour, backend down)
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
set -u
H=$(cd "$(dirname "$0")" && pwd)
if b=$("$INTELXE_HOME/wsitest/gpu_busy.sh"); then echo "ABORT: $b"; exit 9; fi
s() { sysctl -n debug.intelxe.stats | grep -E "^jobs|^TDR|^queues"; }
L=$H/log-$(date +%H%M%S)-${1#--}; mkdir -p "$L"
ICD=$H/libvulkan_intel.dylib; [ "${NVMTL_ICD_LIB:-}" = installed ] && ICD=/Library/GPUBundles/nvmtl/libvulkan_intel.dylib
echo "== before"; s
NVMTL_ENABLE=1 NVMTL_BUNDLE="$H/NVMTLDriver.bundle" NVMTL_ICD_LIB="$ICD" NVMTL_LOG_PATH="$L/nvmtl.log" \
  /usr/bin/perl -e 'alarm 50; exec @ARGV' "$H/mtl_recover" "$@" 2>&1 | tee "$L/out.txt"; rc=${PIPESTATUS[0]}
sleep 1
echo "== after (mtl_recover rc $rc)"; s
grep -E "GPU RECOVERY|GPU recovery|recovery TEST|in flight across|submitted again|disabling backend|reset recovery" "$L/nvmtl.log" | cut -c1-260 | tail -20
pgrep -x WindowServer > /dev/null && echo "WindowServer pid $(pgrep -x WindowServer) running" || echo "WindowServer NOT running"
echo "log: $L"
