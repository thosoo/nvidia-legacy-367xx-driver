#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo "usage: $0 KBUILD_COMMAND_LOG" >&2
    exit 2
fi
log=$1
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
awk '
{
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^(KBUILD_OUTPUT|NV_KERNEL_OUTPUT)=\/lib\/modules\/[^\/[:space:]]+\/build$/) {
            v=$i; sub(/^[^=]*=\/lib\/modules\//, "", v); sub(/\/build$/, "", v); print v
        }
        if ($i == "-C" && (i + 1) <= NF && $(i + 1) ~ /^\/lib\/modules\/[^\/[:space:]]+\/(build|source)$/) {
            v=$(i + 1); sub(/^\/lib\/modules\//, "", v); sub(/\/(build|source)$/, "", v); print v
        }
    }
}
' "$log" | sort -u > "$tmp"
count=$(wc -l < "$tmp")
if [ "$count" -ne 1 ]; then
    echo "expected exactly one kernel release, found $count" >&2
    cat "$tmp" >&2
    exit 1
fi
cat "$tmp"
