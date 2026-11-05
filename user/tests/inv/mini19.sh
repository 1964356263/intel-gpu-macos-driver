# SPDX-License-Identifier: MIT
u() { sudo -n launchctl asuser 501 sudo -u yusuf "$@"; }
r() { sysctl -n debug.nmxaccel_mark_waits debug.nmxaccel_flips debug.nmxaccel_mark_timeouts | tr "\n" " "; echo; }
pgrep -x Safari >/dev/null || { u open -a Safari; sleep 6; }
u osascript -e 'tell application "Safari" to set miniaturized of every window to false'; sleep 2
echo "marks before: $(r)"
u osascript -e 'tell application "Safari" to set miniaturized of front window to true'; sleep 3
echo "marks after:  $(r)"
sudo -n ~/b580/fbcrop 1610 1325 /tmp/mini.ppm >/dev/null 2>&1; ls -la /tmp/mini.ppm | awk '{print $5, $6, $7, $8}'
u osascript -e 'tell application "Safari" to set miniaturized of every window to false'; sleep 2
echo "marks unmin:  $(r)"
grep -c "captures: surface" /tmp/nvmtl.log; grep "captures:\|surface writes:" /tmp/nvmtl.log | head -4 | cut -c1-200
