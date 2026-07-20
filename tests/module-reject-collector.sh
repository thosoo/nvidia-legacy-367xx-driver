#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/source/kernel-source-tree/nvidia-drm" "$tmp/logs"
printf '%s\n' 'rejected hunk body' > "$tmp/source/kernel-source-tree/nvidia-drm/nvidia-drm.Kbuild.rej"
sh "$repo/tools/collect-module-rejects.sh" "$tmp/source" "$tmp/logs"
test -s "$tmp/logs/module-quilt-reject-files.txt"
test -s "$tmp/logs/module-quilt-reject-files-relative.txt"
test -s "$tmp/logs/module-quilt-reject-contents.txt"
grep -Fx "kernel-source-tree/nvidia-drm/nvidia-drm.Kbuild.rej" \
    "$tmp/logs/module-quilt-reject-files-relative.txt" >/dev/null
grep -F "rejected hunk body" "$tmp/logs/module-quilt-reject-contents.txt" >/dev/null
