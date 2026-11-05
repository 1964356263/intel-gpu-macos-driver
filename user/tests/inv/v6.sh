# SPDX-License-Identifier: MIT
W=/tmp/x6; rm -rf $W; mkdir -p $W; chmod 777 $W
crops() { for x in 600 856 1112 1368 1624 1880; do sudo -n $HOME/b580/fbcrop $x 1312 $W/$1_$x.ppm >/dev/null; done; }
sleep 3; crops login
for r in 1 2 3; do killall Dock; sleep 6; crops r$r; done
for x in 0 256 2304; do sudo -n $HOME/b580/fbcrop $x 0 $W/menu_$x.ppm >/dev/null; done
chmod 644 $W/*; ls /tmp/nvmtl-static-linear* 2>/dev/null
