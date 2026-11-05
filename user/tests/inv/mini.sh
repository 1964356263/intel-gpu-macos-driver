# SPDX-License-Identifier: MIT
P=$(pgrep -x WindowServer)
u() { sudo -n launchctl asuser 501 sudo -u yusuf "$@"; }
u osascript -e 'tell application "Safari" to set miniaturized of every window to false'
sleep 2
sudo -n rm -f /tmp/nvmtl-trace-$P.txt /tmp/nvmtl-frame-*
sudo -n touch /tmp/nvmtl-trace-huge /tmp/nvmtl-dump-request /tmp/nvmtl-trace-request
u osascript -e 'tell application "Safari" to set miniaturized of front window to true'
sleep 3
rm -f /tmp/nvmtl-trace-huge /tmp/nvmtl-trace-request /tmp/nvmtl-dump-request
sudo -n wc -l /tmp/nvmtl-trace-$P.txt
sudo -n ~/b580/fbcrop 1610 1325 /tmp/mini.ppm
ls /tmp/nvmtl-frame-*; ps -o pid,comm -p 6199
