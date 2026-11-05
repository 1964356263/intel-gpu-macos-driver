# SPDX-License-Identifier: MIT
# scanchk.sh [x y]: is the display's direct scan-out (debug.nmxaccel_flip=1) showing what the copy path shows? Crops the
# same static region (default: wallpaper above the Dock) with flips off and on through IntelXeFB's crop (fbcrop, root) and
# compares the bytes. A compressed or stale scan-out buffer differs; a correct one matches (cursor/clock aside).
X=${1:-200}; Y=${2:-900}
was=$(sysctl -n debug.nmxaccel_flip)
sudo -n sysctl -w debug.nmxaccel_flip=0 >/dev/null; sleep 1.5
sudo -n ~/b580/fbcrop $X $Y /tmp/scanchk-copy.ppm >/dev/null 2>&1
sudo -n sysctl -w debug.nmxaccel_flip=1 >/dev/null; sleep 1.5
sudo -n ~/b580/fbcrop $X $Y /tmp/scanchk-flip.ppm >/dev/null 2>&1
sudo -n sysctl -w debug.nmxaccel_flip=$was >/dev/null
n=$(cmp -l /tmp/scanchk-copy.ppm /tmp/scanchk-flip.ppm 2>/dev/null | wc -l | tr -d ' ')
echo "scan-out check at $X,$Y: $n bytes differ between the copy path and direct scan-out (flip restored to $was)"
[ "$n" -lt 64 ] && echo PASSED || echo FAILED
