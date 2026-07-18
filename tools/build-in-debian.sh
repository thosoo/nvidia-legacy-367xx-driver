#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 SUITE REPOSITORY_DIRECTORY OUTPUT_DIRECTORY" >&2
    exit 2
fi

suite=$1
repository=$2
out=$3
version=367.134
source=nvidia-graphics-drivers-legacy-367xx
orig=${source}_${version}.orig-amd64.tar.xz
runfile=NVIDIA-Linux-x86_64-${version}.run
sha256=c621c6068c1d09a88a4159963093fa1a28b45c7c989280c273c7d7a2b566c62f

mkdir -p "$out/logs" "$out/artifacts"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl make perl ripgrep git build-essential debhelper-compat devscripts dpkg-dev dh-dkms dkms quilt xz-utils linux-headers-amd64 lintian libvulkan1 po-debconf libglvnd-dev libxext6 kmod
rm -rf /work
mkdir -p /work/packaging /work/import /work/source-package /work/binary-source /work/logs /work/artifacts

if [ -d "$repository/.git" ]; then
    test -z "$(git -C "$repository" status --porcelain)"
    git -C "$repository" archive HEAD | tar -x -C /work/packaging
else
    echo "$repository is not a Git repository" >&2
    exit 2
fi

{
    echo "suite=$suite"
    cat /etc/os-release
    dpkg-query -W build-essential debhelper-compat devscripts dpkg-dev dh-dkms dkms quilt xz-utils linux-headers-amd64 lintian libglvnd-dev 2>/dev/null || true
    find /lib/modules -maxdepth 2 -type l -name build -print
    find /usr/src -maxdepth 1 -type d -name 'linux-headers-*' -print
} > /work/logs/environment.txt

/work/packaging/debian/scripts/fetch-367.134-runfile /work/import /work > /work/logs/fetch.log 2>&1
cat /work/logs/fetch.log

tar -tf "/work/$orig" > /work/logs/orig-contents.txt
grep -Fx "amd64/$runfile" /work/logs/orig-contents.txt
find "/work/import/NVIDIA-Linux-x86_64-$version" -type f -printf '%P\n' | sort > /work/logs/inventory-367.134.txt

cd /work/packaging
tests/no-390xx-leaks.sh
tests/amd64-only.sh
tests/no-proprietary-artifacts.sh
tests/generated-control-drift.sh

set +e
dpkg-buildpackage -us -uc -S > /work/logs/source-build.log 2>&1
source_status=$?
set -e
cat /work/logs/source-build.log
printf '%s\n' "$source_status" > /work/logs/source-build.exit
test "$source_status" -eq 0

set -- /work/${source}_*.dsc
test "$#" -eq 1
dsc=$1
find /work -maxdepth 1 -type f \( -name '*.dsc' -o -name '*.debian.tar.*' -o -name '*.orig*.tar.*' -o -name '*.changes' -o -name '*.buildinfo' \) -printf '%f\n' | sort > /work/logs/source-package-list.txt

rm -rf /work/binary-source
dpkg-source -x "$dsc" /work/binary-source > /work/logs/source-extract.log 2>&1
cat /work/logs/source-extract.log
test -f "/work/binary-source/amd64/$runfile"
printf '%s  %s\n' "$sha256" "/work/binary-source/amd64/$runfile" | sha256sum -c -

cd /work/binary-source
tests/no-390xx-leaks.sh
tests/amd64-only.sh
tests/generated-control-drift.sh

set +e
dpkg-buildpackage -us -uc -b > /work/logs/binary-build.log 2>&1
binary_status=$?
set -e
cat /work/logs/binary-build.log
printf '%s\n' "$binary_status" > /work/logs/binary-build.exit

find /work -maxdepth 1 -type f \( -name '*.deb' -o -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' \) -printf '%f\n' | sort > /work/logs/binary-package-list.txt
cp /work/logs/binary-build.log /work/logs/kernel-source-build.log
grep -n -C 8 -E 'error:|fatal error:|implicit declaration|incompatible pointer|No such file|treated as errors' /work/logs/binary-build.log > /work/logs/kernel-build-excerpt.txt || true
grep -n -E 'kernel-source-tree|CC \[M\]|CONFTEST|nvidia-uvm|nvidia-drm|nvidia-modeset|nv-linux' /work/logs/binary-build.log > /work/logs/kernel-build-progress.txt || true

find /work -maxdepth 1 -type f \( -name '*.deb' -o -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' \) -exec cp -v {} /work/artifacts/ \; >> /work/logs/binary-package-list.txt || true
cp -a /work/logs/. "$out/logs/"
cp -a /work/artifacts/. "$out/artifacts/"

exit "$binary_status"
