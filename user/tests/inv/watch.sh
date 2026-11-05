#!/bin/bash
# SPDX-License-Identifier: MIT
# Bug 1 watcher (root): after the next login, record the Dock while its icons are sharp, then again after the first
# screenshot. Results in /tmp/w/. Gives up after 40 minutes.
W=/tmp/w; rm -rf $W; mkdir -p $W; exec > $W/watch.log 2>&1
D0=$(pgrep -x Dock); echo "start $(date +%T) dock0=$D0"
crops() { for x in 600 856 1112 1368 1624 1880; do $HOME/b580/fbcrop $x 1312 $W/$1_$x.ppm >/dev/null; done; }
trace() {   # $1 tag: WindowServer trace while the Dock redraws (it is relaunched)
  P=$(pgrep -x WindowServer); rm -f /tmp/nvmtl-trace-$P.txt
  touch /tmp/nvmtl-trace-long /tmp/nvmtl-trace-request; sleep 0.6
  sudo -u yusuf killall Dock; sleep 4
  rm -f /tmp/nvmtl-trace-request /tmp/nvmtl-trace-long; sleep 0.5
  cp /tmp/nvmtl-trace-$P.txt $W/$1-trace.txt; echo "$1 trace $(wc -l < $W/$1-trace.txt) lines $(date +%T)"
  sleep 3; crops $1_after
}
for i in $(seq 2400); do D=$(pgrep -x Dock); [ -n "$D" ] && [ "$D" != "$D0" ] && break; sleep 1; done
[ -z "$D" ] || [ "$D" = "$D0" ] && { echo "no login"; exit 0; }
echo "login: dock=$D $(date +%T)"; sleep 5
crops sharp; echo "sharp crops $(date +%T)"
touch $W/marker
trace sharp
for i in $(seq 1800); do N=$(find $HOME/Desktop -name 'Screenshot*' -newer $W/marker | head -1); [ -n "$N" ] && break; sleep 1; done
echo "screenshot: $N $(date +%T)"; sleep 8
crops broken; trace broken
P=$(pgrep -x WindowServer); grep "pid $P " /tmp/nvmtl.log > $W/ws.log
chmod -R a+r $W; echo "done $(date +%T)"
