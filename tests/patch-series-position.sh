#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo "usage: $0 PREPARED_367_KERNEL_TREE" >&2
    exit 2
fi
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pristine=$(readlink -f "$1")
patchdir=$repo/debian/module/debian/patches
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -a "$pristine/." "$work/tree"
sed 's/#HAS_UVM#//g' "$patchdir/series.in" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' > "$work/series"
for target in backport-uvm-mmap-lock-api.patch backport-uvm-core-api-compat.patch; do
    rm -rf "$work/tree"
    cp -a "$pristine/." "$work/tree"
    : > "$work/$target.report"
    while IFS= read -r patch_name; do
        test -n "$patch_name" || continue
        if [ "$patch_name" = "$target" ]; then
            log="$work/$target.apply.log"
            patch -d "$work/tree" -p1 --fuzz=0 < "$patchdir/$patch_name" > "$log" 2>&1
            if grep -E 'fuzz|offset|FAILED|malformed' "$log" >/dev/null; then
                cat "$log" >&2
                exit 1
            fi
            patch -d "$work/tree" -p1 -R --fuzz=0 < "$patchdir/$patch_name" > "$work/$target.reverse.log" 2>&1
            patch -d "$work/tree" -p1 --fuzz=0 < "$patchdir/$patch_name" > "$work/$target.reapply.log" 2>&1
            if grep -E 'fuzz|offset|FAILED|malformed' "$work/$target.reapply.log" >/dev/null; then
                cat "$work/$target.reapply.log" >&2
                exit 1
            fi
            printf '%s\tclean-at-series-position\n' "$target" >> "$work/$target.report"
        else
            patch -d "$work/tree" -p1 < "$patchdir/$patch_name" > "$work/$patch_name.log" 2>&1 || {
                echo "$patch_name" >&2
                cat "$work/$patch_name.log" >&2
                exit 1
            }
        fi
        find "$work/tree" \( -name '*.rej' -o -name '*.orig' \) -print -delete | sed 's/^/removed temporary: /' >> "$work/$target.report"
    done < "$work/series"
done
