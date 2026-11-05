# SPDX-License-Identifier: MIT
W=/tmp/x; mkdir -p $W; chmod 777 $W
crops() { for x in 600 856 1112 1368 1624 1880; do sudo -n $HOME/b580/fbcrop $x 1312 $W/$1_$x.ppm >/dev/null; done; }
case "$1" in
 base) crops base ;;
 relaunch) killall Dock; sleep 5; crops relaunch ;;
 linear) touch /tmp/nvmtl-static-linear; sleep 0.5; killall Dock; sleep 5; crops linear; sleep 1; rm -f /tmp/nvmtl-static-linear; sleep 0.5; crops linear_off ;;
 dump) sudo -n rm -f /tmp/nvmtl-frame-*; touch /tmp/nvmtl-dump-request; sleep 0.5; killall Dock; sleep 4; rm -f /tmp/nvmtl-dump-request; sudo -n sh -c 'cp /tmp/nvmtl-frame-*lv* /tmp/x/ 2>/dev/null'; sudo -n chmod 644 /tmp/x/*; ls /tmp/x | grep lv | head -30; sudo -n rm -f /tmp/nvmtl-frame-* ;;
esac
