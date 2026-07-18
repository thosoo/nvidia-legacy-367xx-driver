#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo "usage: $0 OUTPUT_DIRECTORY" >&2
    exit 2
fi
out=$1
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source=nvidia-graphics-drivers-legacy-367xx
version=367.134
main="$out/${source}_${version}.orig.tar.xz"
amd64="$out/${source}_${version}.orig-amd64.tar.xz"
mkdir -p "$out/import"
"$repo/debian/scripts/fetch-367.134-runfile" "$out/import" "$out"
test -s "$main"
test -s "$amd64"
printf '%s\n' "== $main"
tar -tvf "$main" | sed -n '1,80p'
tar -tf "$main" | grep -Fx "${source}-${version}/" >/dev/null
test "$(tar -tf "$main" | wc -l)" -eq 1
if tar -tf "$main" | grep -E 'NVIDIA-Linux-.*\.run|\.ko(\..*)?$|\.so(\..*)?$'; then
    echo "primary orig unexpectedly contains proprietary payload" >&2
    exit 1
fi
printf '%s\n' "== $amd64"
tar -tvf "$amd64" | sed -n '1,80p'
tar -tf "$amd64" | grep -Fx 'amd64/NVIDIA-Linux-x86_64-367.134.run' >/dev/null
