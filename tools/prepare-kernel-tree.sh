#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "usage: $0 SUITE OUTPUT_DIRECTORY" >&2
    exit 2
fi
suite=$1
out=$2
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=367.134
work=$out/$suite-kernel-work
import=$work/import
pristine=$work/kernel-pristine
series=$work/module-series.txt
mkdir -p "$work" "$import"
"$repo/debian/scripts/fetch-367.134-runfile" "$import" "$work" > "$work/fetch.log" 2>&1
rm -rf "$pristine"
cp -a "$import/NVIDIA-Linux-x86_64-$version/kernel" "$pristine"
cp -al "$import/NVIDIA-Linux-x86_64-$version/NVIDIA_Changelog" "$pristine/"
rm -f "$pristine/nvidia/nv-kernel.o_binary"
cp -al "$import/NVIDIA-Linux-x86_64-$version/kernel/nvidia/nv-kernel.o_binary" "$pristine/nvidia/nv-kernel-amd64.o_binary"
rm -f "$pristine/nvidia-modeset/nv-modeset-kernel.o_binary"
cp -al "$import/NVIDIA-Linux-x86_64-$version/kernel/nvidia-modeset/nv-modeset-kernel.o_binary" "$pristine/nvidia-modeset/nv-modeset-kernel-amd64.o_binary"
sed 's/#HAS_UVM#//g' "$repo/debian/module/debian/patches/series.in" | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' > "$series"
find "$pristine" -type f -print0 | sort -z | xargs -0 sha256sum > "$work/kernel-pristine.sha256"
printf '%s\n' "$pristine"
