#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=pr5
if [ "$#" -eq 2 ] && [ "$1" = "--full-series" ]; then
    mode=full
    pristine=$(readlink -f "$2")
elif [ "$#" -eq 1 ]; then
    pristine=$(readlink -f "$1")
else
    echo "usage: $0 PREPARED_367_KERNEL_TREE" >&2
    echo "       $0 --full-series PREPARED_367_KERNEL_TREE" >&2
    exit 2
fi
test -d "$pristine"
patchdir=$repo/debian/module/debian/patches
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -a "$pristine/." "$work/tree"
series=$work/active-series
sed 's/#HAS_UVM#//g' "$patchdir/series.in" |
    sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' > "$series"

apply_patch_checked()
{
    patch_name=$1
    fuzz_arg=${2:-}
    log=$work/$patch_name.log
    if [ -n "$fuzz_arg" ]; then
        patch -d "$work/tree" -p1 "$fuzz_arg" < "$patchdir/$patch_name" > "$log" 2>&1
    else
        patch -d "$work/tree" -p1 < "$patchdir/$patch_name" > "$log" 2>&1
    fi || {
        printf '%s\n' "$patch_name" > "$work/first-failed-patch.txt"
        cat "$log" >&2
        exit 1
    }
}

if [ "$mode" = pr5 ]; then
    pr5_patches='
backport-vmalloc-signature.patch
backport-ioremap-nocache.patch
backport-smp-call-return-types.patch
backport-swiotlb-detection.patch
fix-sg-allocation-conftests.patch
backport-acpi-api-compat.patch
backport-dma-mask-api.patch
backport-procfs-api-compat.patch
normalize-module-instances-warning.patch
backport-timekeeping-scheduler-mmap-lock-api.patch
'
    while IFS= read -r patch_name; do
        test -n "$patch_name" || continue
        if printf '%s\n' "$pr5_patches" | grep -Fx "$patch_name" >/dev/null; then
            apply_patch_checked "$patch_name" --fuzz=0
            if grep -E 'fuzz|offset|FAILED|malformed' "$work/$patch_name.log" >/dev/null; then
                cat "$work/$patch_name.log" >&2
                exit 1
            fi
            last_applied=$patch_name
        else
            apply_patch_checked "$patch_name"
        fi
        find "$work/tree" \( -name '*.rej' -o -name '*.orig' \) -delete
        if [ "${last_applied:-}" = backport-timekeeping-scheduler-mmap-lock-api.patch ]; then
            break
        fi
    done < "$series"
    if [ "${last_applied:-}" != backport-timekeeping-scheduler-mmap-lock-api.patch ]; then
        echo 'focused PR5 series did not reach backport-timekeeping-scheduler-mmap-lock-api.patch' >&2
        exit 1
    fi
else
    : > "$work/full-series-results.tsv"
    while IFS= read -r patch_name; do
        test -n "$patch_name" || continue
        log=$work/$patch_name.log
        if patch -d "$work/tree" -p1 < "$patchdir/$patch_name" > "$log" 2>&1; then
            if grep -E 'fuzz|offset' "$log" >/dev/null; then
                printf '%s\t%s\n' "$patch_name" "applied-with-fuzz-or-offset" >> "$work/full-series-results.tsv"
            else
                printf '%s\tclean\n' "$patch_name" >> "$work/full-series-results.tsv"
            fi
        else
            printf '%s\n' "$patch_name" > "$work/first-failed-patch.txt"
            printf '%s\treject\n' "$patch_name" >> "$work/full-series-results.tsv"
            cat "$log" >&2
            exit 1
        fi
    done < "$series"
    expected=$(wc -l < "$series")
    applied=$(wc -l < "$work/full-series-results.tsv")
    if [ "$expected" -ne "$applied" ]; then
        echo "full series incomplete: expected $expected applied $applied" >&2
        exit 1
    fi
fi

if find "$work/tree" \( -name '*.rej' -o -name '.pc' \) -print | grep . >/dev/null; then
    echo 'patch integrity test left reject/quilt state files' >&2
    exit 1
fi
find "$work/tree" -name '*.orig' -delete
