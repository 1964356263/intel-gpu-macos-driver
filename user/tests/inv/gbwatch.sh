#!/bin/bash
# SPDX-License-Identifier: MIT
# Geekbench OpenCL watcher: waits (up to 40 min) for a Geekbench benchmark process, then takes three 20 s `sample`s of it
# spread over the run, plus the plugin's per-process log lines. Output in /tmp/gbw/.
W=/tmp/gbw; rm -rf $W; mkdir -p $W; exec > $W/watch.log 2>&1
echo "armed $(date +%T)"
# a Geekbench process that is busy (the app sits idle between runs): above 25% CPU
pick() { ps -axo pid=,pcpu=,command= | grep -E "geekbench_avx2|Geekbench 7.app/Contents/MacOS" | grep -v grep | sort -k2 -nr | awk '$2 > 25 {print $1; exit}'; }
for i in $(seq 1200); do P=$(pick); [ -n "$P" ] && break; sleep 2; done
[ -z "$P" ] && { echo "no geekbench"; exit 0; }
echo "found pid $P $(ps -o command= -p $P | cut -c1-120) $(date +%T)"
for k in 1 2 3; do
  sleep $([ $k = 1 ] && echo 8 || echo 25)
  P2=$(pick); [ -n "$P2" ] && P=$P2 || { echo "gone before sample $k"; break; }
  echo "sample $k of pid $P $(date +%T)"; /usr/bin/sample $P 20 -file $W/sample$k.txt >/dev/null 2>&1; echo "sample $k done $(date +%T)"
done
echo "done $(date +%T)"
