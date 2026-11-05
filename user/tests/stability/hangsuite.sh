#!/bin/bash
# SPDX-License-Identifier: MIT
# hangsuite.sh t0|t1|t3 : one GPU hang-recovery step (rb3+), each under 60 s. Aborts when a game/benchmark runs.
#   t0  bounded job (65536 iterations): rc 0, no counter changes
#   t1  REAL compute-engine hang: the kernel must end it (GuC engine reset or job watchdog), rc 2 = VK_ERROR_DEVICE_LOST
#   t3  real hang, vkhang killed with -9 after 2 s: the process must be gone within a few seconds (queue teardown)
# Prints the B580 counters before/after, the WindowServer pid before/after and the kernel's G2H log tail.
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
set -u
H=$INTELXE_HOME/rb1; STEP=${1:-t0}
if b=$("$INTELXE_HOME/wsitest/gpu_busy.sh"); then echo "ABORT: $b"; exit 9; fi
c() { sysctl -n debug.intelxe.stats | grep -E "^jobs|^TDR|^queues"; }
WS0=$(pgrep -x WindowServer); echo "== $STEP $(date +%T) WindowServer $WS0"; c
case $STEP in
t0) "$H/vkhang" --iters 65536 --wait-s 5; rc=$? ;;
t1) "$H/vkhang" --wait-s 25; rc=$? ;;
t3) "$H/vkhang" --wait-s 25 > /tmp/vkhang-t3.txt 2>&1 & P=$!
    sleep 2; t=$(date +%s); kill -9 $P
    for i in $(seq 1 150); do kill -0 $P 2>/dev/null || break; sleep 0.1; done
    if kill -0 $P 2>/dev/null; then echo "vkhang STILL ALIVE 15 s after kill -9: $(ps -o stat=,time= -p $P)"; rc=99
    else echo "vkhang gone $(( $(date +%s) - t )) s after kill -9"; rc=0; fi
    cat /tmp/vkhang-t3.txt ;;
*) echo "usage: $0 t0|t1|t3"; exit 1 ;;
esac
sleep 2
WS1=$(pgrep -x WindowServer); echo "== after (rc $rc) WindowServer $WS1$( [ "$WS0" != "$WS1" ] && echo '  <-- WINDOWSERVER CHANGED')"; c
echo "== G2H log (last 10)"; sudo -n sysctl -n debug.intelxe.g2h 2>/dev/null | tail -10
