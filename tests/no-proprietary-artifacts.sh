#!/bin/sh
set -eu
patterns='(^|/)NVIDIA-Linux-.*\.run$|\.ko(\..*)?$|\.deb$|\.dsc$|\.changes$|\.buildinfo$|\.orig.*\.tar\.|(^|/)NVIDIA-Linux-.*/|(^|/)var/lib/dkms/|(^|/)usr/src/nvidia-'
inventory=$(mktemp)
matches=$(mktemp)
trap 'rm -f "$inventory" "$matches"' EXIT
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    set +e
    git ls-files > "$inventory"
    git_status=$?
    set -e
    if [ "$git_status" -ne 0 ]; then
        echo "git ls-files failed with status $git_status" >&2
        exit "$git_status"
    fi
else
    set +e
    find . -type f -o -type d > "$inventory"
    find_status=$?
    set -e
    if [ "$find_status" -ne 0 ]; then
        echo "find failed with status $find_status" >&2
        exit "$find_status"
    fi
fi
set +e
rg -n "$patterns" "$inventory" > "$matches"
rg_status=$?
set -e
case "$rg_status" in
    0) echo 'proprietary/generated artifact found:' >&2; cat "$matches" >&2; exit 1 ;;
    1) exit 0 ;;
    *) echo "ripgrep failed with status $rg_status" >&2; exit "$rg_status" ;;
esac
