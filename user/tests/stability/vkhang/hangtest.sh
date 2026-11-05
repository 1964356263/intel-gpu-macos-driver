#!/bin/bash
# SPDX-License-Identifier: MIT
# hangtest.sh [vkhang options]: one vkhang run with the B580 counters around it. Finishes in under 60 s with the
# default --wait-s 25. Aborts when a game or benchmark runs.
#   hangtest.sh --iters 1000000             a bounded GPU job (no hang; checks the tool)
#   hangtest.sh                             a REAL HANG on the compute engine (CCS): only the kernel can end it
#   hangtest.sh --family render ...         the same on the render engine (RCS), where WindowServer works
# Expected for a real hang with the rb1 kernel: within ~10.5 s (debug.intelxe.job_timeout_ms) the fence wait ends with
# VK_ERROR_DEVICE_LOST (rc 2), "TDR: checks 1" or "GuC context resets 1" and "bans +1" in the stats, no GT reset,
# WindowServer keeps drawing, and a second run of vk_smoke/mtl_tests passes.
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
set -u
H=$(cd "$(dirname "$0")" && pwd)
if b=$("$INTELXE_HOME/wsitest/gpu_busy.sh"); then echo "ABORT: $b"; exit 9; fi
s() { sysctl -n debug.intelxe.stats | grep -E "^jobs|^TDR|^queues"; }
echo "== before"; s
"$H/vkhang" --wait-s 25 "$@"; rc=$?
sleep 1
echo "== after (vkhang rc $rc)"; s
echo "== G2H log (root)"; sudo -n sysctl -n debug.intelxe.g2h 2>/dev/null | tail -12
pgrep -x WindowServer > /dev/null && echo "WindowServer pid $(pgrep -x WindowServer) running" || echo "WindowServer NOT running"
