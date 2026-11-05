#!/bin/sh
# SPDX-License-Identifier: MIT
# rd.sh VARIANT [VAR=value ...] -- [codecs] : rate-distortion points of the B580 VideoToolbox encoders under test
# (test/libintelxevenc.dylib via encreg, test/ff FFmpeg), 1080p60 VBR 3 / 6 / 12 Mbit/s, GOP 120, then PSNR/SSIM/VMAF
# (vmaf.sh). Extra VAR=value pairs go into the encoder's environment (INTELXE_ANV=<test Mesa>, INTELXEVENC_QUALITY=,
# INTELXEVENC_BFRAMES=). Results: results/rd_VARIANT.txt. Stops if the B580 health counters move.
cd "$(dirname "$0")"
V=$1; shift; EXTRA=""
while [ $# -gt 0 ] && [ "$1" != "--" ]; do EXTRA="$EXTRA $1"; shift; done; [ "$1" = "--" ] && shift
CODECS=${*:-"h264 hevc av1"}
RES=${RD_RES:-1080p60}; CONTENT=${RD_CONTENT:-aerial}
case $RES in 1080p60) WH=1920x1080; FR=600; BRS="3 6 12";; 2160p60) WH=3840x2160; FR=300; BRS="12 25 50";; esac
SRC=raw/$RES.nv12; [ $CONTENT != aerial ] && SRC=raw/${CONTENT}_$RES.nv12
VN=$V; [ $CONTENT != aerial ] && VN=$V-$CONTENT
H0=$(./health.sh | sed 's/ java=.*//')
mkdir -p out/rd results
for c in $CODECS; do
	e=$c; [ $c = av1 ] && e=ivf
	for mb in $BRS; do
		H=$(./health.sh | sed 's/ java=.*//'); [ "$H" != "$H0" ] && { echo "HEALTH CHANGED: $H" >> results/rd_${VN}_$RES.txt; exit 3; }
		o=out/rd/${VN}_${c}_${RES}_8_vbr${mb}.$e
		./tb.sh 60 env DYLD_LIBRARY_PATH=$PWD/test/ff:/usr/local/lib INTELXEVENC_CODECS=hevc,h264,av1 INTELXEVENC_LIB=$PWD/test/libintelxevenc.dylib \
			DYLD_INSERT_LIBRARIES=$PWD/encreg.dylib $EXTRA ./vtencq $c $WH $SRC $FR $o --bitrate $((mb*1000000)) --fps 60 --keyint 120 \
			2>&1 | grep RESULT | sed "s|^|$V |" >> results/rd_${VN}_${RES}_enc.txt
	done
done
for c in $CODECS; do ./vmaf.sh out/rd/${VN}_${c}_${RES}_* >> results/rd_${VN}_$RES.txt 2>&1; done
echo "RD DONE $(./health.sh)" >> results/rd_${VN}_$RES.txt
