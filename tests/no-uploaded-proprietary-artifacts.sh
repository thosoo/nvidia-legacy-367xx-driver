#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo "usage: $0 DIRECTORY" >&2
    exit 2
fi
dir=$1
test -d "$dir"
prohibited=$(mktemp)
trap 'rm -f "$prohibited"' EXIT
set +e
find "$dir" \
    \( -name 'NVIDIA-Linux-*.run' -o -name 'NVIDIA-Linux-*' -o \
       -name '*.ko' -o -name '*.ko.*' -o -name '*.deb' -o \
       -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' -o \
       -name '*.orig*.tar.*' -o -name '*.so' -o -name '*.so.*' \) \
    -print > "$prohibited"
find_status=$?
set -e
if [ "$find_status" -ne 0 ]; then
    echo "find failed with status $find_status" >&2
    exit "$find_status"
fi
if [ -s "$prohibited" ]; then
    echo 'forbidden proprietary/generated upload artifact found:' >&2
    cat "$prohibited" >&2
    exit 1
fi
