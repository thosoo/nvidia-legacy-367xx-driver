#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -ne 1 ]; then
    echo "usage: $0 PREPARED_367_KERNEL_TREE" >&2
    exit 2
fi
pristine=$(readlink -f "$1")
test -d "$pristine"
patchdir=$repo/debian/module/debian/patches
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -a "$pristine/." "$work/tree"
pre=$work/pre-series
sed 's/#HAS_UVM#//g' "$patchdir/series.in" |
    sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' |
    sed '/backport-vmalloc-signature.patch/,$d' > "$pre"
while IFS= read -r patch; do
    patch -d "$work/tree" -p1 --fuzz=0 < "$patchdir/$patch" >/dev/null
 done < "$pre"
find "$work/tree" \( -name '*.rej' -o -name '*.orig' \) -delete
for patch in \
    backport-vmalloc-signature.patch \
    backport-ioremap-nocache.patch \
    backport-smp-call-return-types.patch \
    backport-swiotlb-detection.patch \
    fix-sg-allocation-conftests.patch \
    backport-acpi-api-compat.patch \
    backport-dma-mask-api.patch \
    normalize-module-instances-warning.patch
do
    log=$work/$patch.log
    patch -d "$work/tree" -p1 --fuzz=0 < "$patchdir/$patch" > "$log" 2>&1 || {
        cat "$log" >&2
        exit 1
    }
    if grep -E 'fuzz|offset|FAILED|malformed' "$log" >/dev/null; then
        cat "$log" >&2
        exit 1
    fi
 done
if find "$work/tree" \( -name '*.rej' -o -name '*.orig' \) -print | grep . >/dev/null; then
    echo 'patch integrity test left reject/orig files' >&2
    exit 1
fi
