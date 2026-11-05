#!/bin/sh
# SPDX-License-Identifier: MIT
# Phase 1 gate after a reboot: gate.sh OUTPREFIX. Each remote call is time-boxed (<= 60 s). Run from the Mac.
D=$(dirname "$0"); R="$D/rsh"; O=${1:-$D/after}
ENV='cd ~/b580; export NVMTL_ENABLE=1 NVMTL_ICD_LIB=$HOME/b580/prof/mesa-rel/libvulkan_intel.dylib NVMTL_BUNDLE=$HOME/b580/fix16/NVMTLDriver.bundle;'
$R 30 'sysctl -n kern.boottime; ls -t /Library/Logs/DiagnosticReports/ | grep -i "^kernel.*panic" | head -3; kextstat | grep -i intelxe; sysctl -n debug.intelxe.stats; sudo -n sysctl -n debug.intelxe.state | tail -25' > $O-0.txt 2>&1
$R 60 "$ENV"' echo "tests: $(./mtl_tests 2>&1 | tail -1) | mip: $(./mtl_tests mip 2>&1 | grep -v "implemented in both\|preload" | grep "FAIL\|PASSED\|failure" | tr "\n" " ") | bt: $(inv/bt | tail -1) | race: $(NVMTL_CAPTURE_WAIT=1 inv/surftest race frames 2 | tail -1)"' > $O-1.txt 2>&1
$R 60 "$ENV"' echo "empty: $(inv/emptytest 2>&1 | tail -1)"; echo "cltr: $(inv/cltr 2>&1 | tail -1) | glflat: $(inv/glflat 1 short 2>&1 | grep -o "^PASS\|^FAIL") $(inv/glflat 1 byte 2>&1 | grep -o "^PASS\|^FAIL")"; echo "ppool: $(inv/ppool 2>&1 | grep -v "implemented in both\|preload" | tr "\n" " ")"' > $O-2.txt 2>&1
$R 60 "$ENV"' echo "memory: $(perl -e "alarm 40; exec @ARGV" inv/clchurn 3000 25 2>&1 | grep "PASSED\|FAILED\|->")"' > $O-3.txt 2>&1
$R 60 "$ENV"' echo "metal churn: $(perl -e "alarm 25; exec @ARGV" inv/churn 2>&1 | grep Private | cut -c1-70) | $(perl -e "alarm 25; exec @ARGV" ./mtl_tests bw 2>&1 | grep "256 MB random" | tr -s " ")"; echo "coherence: $(inv/clcoh 2>&1 | tail -1)"; echo "atomics: $(inv/clatom 2>&1 | grep -v "implemented in both\|preload" | awk "{print \$1, \$2, \$3}" | tr "\n" " ")"; echo "clpw: $(inv/clpw 2>&1 | tail -1)"; echo "clrw: $(perl -e "alarm 20; exec @ARGV" inv/clrw 6 2>&1 | grep round | tr -s " " | cut -c1-70 | tr "\n" "|")"' > $O-4.txt 2>&1
$R 60 "$ENV"' cd prof; for t in mtl_lat vlat; do echo "== $t"; perl -e "alarm 15; exec @ARGV" ./$t 2>&1 | grep -v "implemented in both\|preload" | tail -8; done' > $O-5.txt 2>&1
$R 60 "$ENV"' cd prof; perl -e "alarm 20; exec @ARGV" ./rtt 2>&1 | grep -v "implemented in both\|preload"; sysctl debug.nmxaccel_iop_ok debug.nmxaccel_flips debug.nmxaccel_flip_late debug.nmxaccel_flip_refused' > $O-6.txt 2>&1
$R 60 'sudo -n log show --last 30m --style compact --predicate "process == \"WindowServer\" AND (messageType == 16 OR messageType == 17)" 2>&1 | tail -n +2 | cut -c 25- | sed -E "s/\[[0-9]+:[0-9a-f]+\]//; s/0x[0-9a-f]+/X/g; s/[0-9]+/N/g" | sort | uniq -c | sort -rn | head -10; sysctl -n debug.intelxe.stats; sudo -n sysctl -n debug.intelxe.g2h | tail -20' > $O-7.txt 2>&1
cat $O-*.txt
