# SPDX-License-Identifier: MIT
W=/tmp/x2; mkdir -p $W; chmod 777 $W
crops() { for x in 600 856 1112 1368 1624 1880; do sudo -n $HOME/b580/fbcrop $x 1312 $W/$1_$x.ppm >/dev/null; done; }
rm -f /tmp/nvmtl-static-linear /tmp/nvmtl-static-linear-*
case "$1" in
 none) sleep 0.5; killall Dock; sleep 5; crops none ;;
 s*) n=${1#s}; touch /tmp/nvmtl-static-linear-$n; sleep 0.5; killall Dock; sleep 5; crops slot$n; rm -f /tmp/nvmtl-static-linear-$n ;;
 dump) sudo -n rm -f /tmp/nvmtl-psodump-*; touch /tmp/nvmtl-dump-request; sleep 0.5; killall Dock; sleep 4; rm -f /tmp/nvmtl-dump-request; sleep 0.5
       sudo -n sh -c 'cp /tmp/nvmtl-psodump-* /tmp/x2/ 2>/dev/null; chmod 644 /tmp/x2/*; rm -f /tmp/nvmtl-frame-*'; ls /tmp/x2 | grep psodump ;;
esac
