#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=367.134
mode=runfile
if [ "$#" -eq 3 ] && [ "$1" = "--from-package-build" ]; then
    mode=package
    source_tree=$(readlink -f "$2")
    out=$3
elif [ "$#" -eq 2 ]; then
    suite=$1
    out=$2
else
    echo "usage: $0 SUITE OUTPUT_DIRECTORY" >&2
    echo "       $0 --from-package-build PREPARED_BUILD_KERNEL OUTPUT_DIRECTORY" >&2
    exit 2
fi
out=$(readlink -m "$out")
work=$out/${suite:-package}-kernel-work
import=$work/import
pristine=$work/kernel-pristine
series=$work/module-series.txt
mkdir -p "$work" "$import"
rm -rf "$pristine"
if [ "$mode" = package ]; then
    test -d "$source_tree" || { echo "prepared build kernel not found: $source_tree" >&2; exit 1; }
    cp -a "$source_tree" "$pristine"
    echo "package-build:$source_tree" > "$work/tree-source.txt"
else
    "$repo/debian/scripts/fetch-367.134-runfile" "$import" "$work" > "$work/fetch.log" 2>&1
    cp -a "$import/NVIDIA-Linux-x86_64-$version/kernel" "$pristine"
    cp -al "$import/NVIDIA-Linux-x86_64-$version/NVIDIA_Changelog" "$pristine/"
    {
        echo "raw-runfile:$import/NVIDIA-Linux-x86_64-$version/kernel"
        echo "blob-rename:nvidia/nv-kernel.o_binary -> nvidia/nv-kernel-amd64.o_binary"
        echo "blob-rename:nvidia-modeset/nv-modeset-kernel.o_binary -> nvidia-modeset/nv-modeset-kernel-amd64.o_binary"
    } > "$work/tree-source.txt"
    rm -f "$pristine/nvidia/nv-kernel.o_binary"
    cp -al "$import/NVIDIA-Linux-x86_64-$version/kernel/nvidia/nv-kernel.o_binary" "$pristine/nvidia/nv-kernel-amd64.o_binary"
    rm -f "$pristine/nvidia-modeset/nv-modeset-kernel.o_binary"
    cp -al "$import/NVIDIA-Linux-x86_64-$version/kernel/nvidia-modeset/nv-modeset-kernel.o_binary" "$pristine/nvidia-modeset/nv-modeset-kernel-amd64.o_binary"
    diff -qr "$import/NVIDIA-Linux-x86_64-$version/kernel" "$pristine" > "$work/raw-vs-prepared-kernel.diff" 2>&1 || true
fi
sed 's/#HAS_UVM#//g' "$repo/debian/module/debian/patches/series.in" | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' > "$series"
find "$pristine" -type f -print0 | sort -z | xargs -0 sha256sum > "$work/kernel-pristine.sha256"
find "$pristine" -type f -printf '%P\n' | sort > "$work/kernel-pristine-files.txt"
printf '%s\n' "$pristine"
