#!/bin/sh
# Regenerate every parity artefact in one go: data/*.json, docs/parity/index.html (embedded data), docs/parity/svg/*.svg,
# docs/parity/HISTORY.md, and one new data/history.json entry.
#
#   LINUX=/path/linux [MESA=/path/mesa MESA_BUILD=/path/mesa/build NEO=/path/compute-runtime] [MEDIA_DRIVER=/path/media-driver] \
#     [MEDIAKIT=/path/mediakit] [LABEL="kernel rb7i"] \
#     tools/parity/build.sh
#
# LINUX: sparse checkout of torvalds/linux or drm-tip with drivers/gpu/drm/xe, drivers/gpu/drm/i915/display and
# include/uapi/drm/xe_drm.h (see docs/parity/README.md). MESA/MESA_BUILD: our patched Mesa tree and its meson build dir
# (optional: without them the Mesa section is left out). MEDIAKIT: the mediakit folder with out_mac/results_mac.txt
# (optional: without it data/video.json is kept as it is). NEO: sparse checkout of intel/compute-runtime with
# shared/source/os_interface/linux (with MESA it enables the need classes and docs/parity/TODO.md). MEDIA_DRIVER: a checkout
# of intel/media-driver (optional: without it data/caps.json is kept as it is); its capability tables give data/caps.json,
# from which video.py takes what Intel does not offer on the B580 and platforms.py the video rows of every platform.
# platforms.py writes docs/PLATFORMS.md, docs/parity/svg/platforms.svg and the README's platform table. CTS runs are
# imported separately with cts_import.py; the newest entry of data/cts/runs.json is drawn.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
: "${LINUX:?set LINUX to the Linux tree}"
py=python3

if [ -n "${MESA:-}" ]; then
	$py "$here/scan.py" --linux "$LINUX" --mesa "$MESA" ${MESA_BUILD:+--mesa-build "$MESA_BUILD"} --html "$root/docs/parity/index.html"
else
	$py "$here/scan.py" --linux "$LINUX" --html "$root/docs/parity/index.html"
fi
$py "$here/uapi.py" --linux "$LINUX"
if [ -n "${MESA:-}" ] && [ -n "${NEO:-}" ]; then
	$py "$here/consumers.py" --linux "$LINUX" --mesa "$MESA" --neo "$NEO"
fi
if [ -n "${MEDIA_DRIVER:-}" ]; then
	$py "$here/caps.py" --media-driver "$MEDIA_DRIVER"
fi
if [ -n "${MEDIAKIT:-}" ] && [ -f "$MEDIAKIT/out_mac/results_mac.txt" ]; then
	$py "$here/video.py" --mediakit "$MEDIAKIT"
fi
$py "$here/render.py" --history-append --label "${LABEL:-}"
$py "$here/next.py"
$py "$here/platforms.py"
