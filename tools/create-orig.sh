#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo "usage: $0 OUTPUT_DIRECTORY" >&2
    exit 2
fi
out=$1
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$out/import"
"$repo/debian/scripts/fetch-367.134-runfile" "$out/import" "$out"
tar -tvf "$out/nvidia-graphics-drivers-legacy-367xx_367.134.orig-amd64.tar.xz" | sed -n '1,80p'
tar -tf "$out/nvidia-graphics-drivers-legacy-367xx_367.134.orig-amd64.tar.xz" | grep -Fx 'amd64/NVIDIA-Linux-x86_64-367.134.run' >/dev/null
