#!/bin/sh
# SPDX-License-Identifier: MIT
# health.sh: one line of the B580 health counters (bans, GuC context resets, GT resets, leaked queues) + guard checks
s=$(sysctl -n debug.intelxe.stats)
b=$(echo "$s" | sed -n 's/.*; bans \([0-9]*\).*/\1/p')
g=$(echo "$s" | sed -n 's/.*GuC context resets \([0-9]*\);.*/\1/p')
t=$(echo "$s" | sed -n 's/.*GT resets \([0-9]*\) .*/\1/p')
l=$(echo "$s" | sed -n 's/.*leaked \([0-9]*\);.*/\1/p')
j=$(pgrep -l java | head -1); gb=$(pgrep -l geekbench | head -1)
echo "HEALTH bans=$b guc_resets=$g gt_resets=$t leaked=$l java=${j:-none} gb=${gb:-none} gpu_jobs=$(pgrep -fl 'vk-cts|deqp|wine|vkhang' | wc -l | tr -d ' ')"
