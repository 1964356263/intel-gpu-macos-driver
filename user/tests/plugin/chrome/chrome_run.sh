#!/bin/bash
# SPDX-License-Identifier: MIT
# chrome_run.sh <tag> <seconds> [extra chrome args...]: Chrome on scroll.html in the GUI session with its own profile
# (/tmp/d3/chrome-prof), console to /tmp/d3/<tag>.txt; the instance (only processes with that profile) is closed after.
INTELXE_HOME=${INTELXE_HOME:-$HOME/b580}   # where the B580 tools and test builds live on the test machine
T=$1; S=$2; shift 2; H=$INTELXE_HOME/d3work
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; P=/tmp/d3/chrome-prof
"$H/g.sh" /usr/bin/true >/dev/null || { "$H/g.sh" /usr/bin/true; exit 3; }
mkdir -p $P
( "$H/gui.sh" chrome-$T ${CHROME_ENV:-X=1} -- "$CH" --user-data-dir=$P --no-first-run --no-default-browser-check --disable-sync --enable-logging=stderr --v=0 \
     --window-size=1600,1000 --window-position=60,60 "$@" "file://$H/scroll.html?t=$S${PAGE_ARGS:-}" > /dev/null 2>&1 & )
for i in $(seq 1 20); do sleep 0.5; grep -q "SCROLLTEST fps" /tmp/d3/chrome-$T.txt 2>/dev/null && break; done
sleep 1; f0=$(sysctl -n debug.nmxaccel_flips); t0=$(date +%s); sleep 6; f1=$(sysctl -n debug.nmxaccel_flips); t1=$(date +%s)
echo "FLIPS: $(( (f1 - f0) / (t1 - t0) ))/s on the panel while scrolling ($((f1 - f0)) in $((t1 - t0)) s); Chrome CPU %: $(ps -axo pcpu,command | grep -- "--user-data-dir=$P" | grep -v grep | awk '{s+=$1} END{print s}')"
for i in $(seq 1 $((S + 12))); do sleep 1; grep -q "SCROLLTEST done" /tmp/d3/chrome-$T.txt 2>/dev/null && break; done
pkill -f -- "--user-data-dir=$P" ; sleep 1; pkill -9 -f -- "--user-data-dir=$P" 2>/dev/null
grep -a "SCROLLTEST" /tmp/d3/chrome-$T.txt | sed 's/.*SCROLLTEST/SCROLLTEST/; s/", source.*//' | cut -c1-160
grep -a -i "gpu process\|GPU access\|software\|blocklist\|disabled" /tmp/d3/chrome-$T.txt | cut -c1-200 | head -5
