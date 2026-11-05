#!/bin/bash
# SPDX-License-Identifier: MIT
# cmp_all.sh <bundleA> <bundleB> <classic|buffer> <tag>: all mtl_bind modes on both, ns/draw side by side and image compare
A=$1; B=$2; M=$3; T=$4; H=$(cd "$(dirname "$0")" && pwd)
MODES1="none bytes vbo tex samp gl glidx"; MODES2="argbuf pso cdisp texbuf stex fetch tess"
for side in a b; do bb=$A; [ $side = b ] && bb=$B
  for half in 1 2; do ms=$MODES1; [ $half = 2 ] && ms=$MODES2
    "$H/bind_cmp.sh" "$bb" /tmp/d3/$T-$side$half $M $ms > /tmp/d3/$T-$side$half.txt 2>&1 || { echo "run failed $side$half"; cat /tmp/d3/$T-$side$half.txt | tail -3; exit 1; }
  done; done
for half in 1 2; do
  join <(awk '/enc\/draw/{print $1, $4}' /tmp/d3/$T-a$half.txt | sort) <(awk '/enc\/draw/{print $1, $4}' /tmp/d3/$T-b$half.txt | sort) | while read m x y; do
    s=SAME; f=$(ls /tmp/d3/$T-a$half/$m.* 2>/dev/null | head -1); cmp -s "$f" /tmp/d3/$T-b$half/$(basename "$f") || s=DIFF
    printf "%-7s %6s %6s ns/draw  %s\n" $m $x $y $s; done; done
