#!/bin/sh
# SPDX-License-Identifier: MIT
# vmaf.sh file...: PSNR / SSIM / VMAF (vmaf_v0.6.1) of encoded streams against their master, CPU only, with the
# reference ffmpeg in bin/ (libdav1d decodes AV1). Name pattern <path>_<codec>_<res>_<bits>_<mode><mbps>.<ext>.
# One line per file: name frames kbps peak1s_kbps psnr_y psnr_avg ssim_all vmaf
cd "$(dirname "$0")"
F=./bin/ffmpeg
for f in "$@"; do
	b=$(basename "$f"); base=${b%.*}
	res=$(echo $base | cut -d_ -f3); bits=$(echo $base | cut -d_ -f4)
	var=$(echo $base | cut -d_ -f1)
	cont=""; case $var in *-drive) cont=drive_;; esac
	m=clips/mezz_$cont$res.mp4; pf=yuv420p
	[ "$bits" = 10 ] && { m=clips/mezz10_$res.mp4; pf=yuv420p10le; }
	./bin/ffprobe -v error -select_streams v:0 -show_entries packet=size -of csv=p=0 "$f" > /tmp/vm_sizes.$$
	np=$(wc -l < /tmp/vm_sizes.$$ | tr -d ' ')
	kb=$(awk '{s+=$1} END {if (NR) printf "%.0f", s*8/1000/(NR/60)}' /tmp/vm_sizes.$$)
	pk=$(awk '{a[NR]=$1; w+=$1; if (NR>60) w-=a[NR-60]; if (NR>=60 && w>m) m=w} END {printf "%.0f", m*8/1000}' /tmp/vm_sizes.$$)
	rm -f /tmp/vm_sizes.$$
	out=$($F -hide_banner -nostdin -nostats -i "$f" -i $m -lavfi \
		"[0:v]setparams=range=tv:color_primaries=unknown:color_trc=unknown:colorspace=unknown,format=$pf,setpts=N/60/TB,split=3[d1][d2][d3];[1:v]setparams=range=tv:color_primaries=unknown:color_trc=unknown:colorspace=unknown,format=$pf,setpts=N/60/TB,split=3[r1][r2][r3];[d1][r1]psnr;[d2][r2]ssim;[d3][r3]libvmaf=n_threads=16" -f null - 2>&1)
	py=$(echo "$out" | grep "PSNR y:" | sed 's/.* y:\([0-9.inf]*\).*/\1/')
	pa=$(echo "$out" | grep "PSNR y:" | sed 's/.*average:\([0-9.inf]*\).*/\1/')
	sa=$(echo "$out" | grep "SSIM Y:" | sed 's/.*All:\([0-9.]*\).*/\1/')
	vm=$(echo "$out" | grep "VMAF score" | sed 's/.*VMAF score: *\([0-9.]*\).*/\1/')
	echo "$base $np $kb $pk ${py:--} ${pa:--} ${sa:--} ${vm:--}"
done
