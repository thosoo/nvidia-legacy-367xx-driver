#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 SUITE REPOSITORY_DIRECTORY OUTPUT_DIRECTORY" >&2
    exit 2
fi

suite=$1
repository=$(readlink -f "$2")
out=$(readlink -m "$3")
version=367.134
source=nvidia-graphics-drivers-legacy-367xx
main_orig=${source}_${version}.orig.tar.xz
amd64_orig=${source}_${version}.orig-amd64.tar.xz
runfile=NVIDIA-Linux-x86_64-${version}.run
sha256=c621c6068c1d09a88a4159963093fa1a28b45c7c989280c273c7d7a2b566c62f
current_stage=initialize

rm -rf /work
mkdir -p "$out/logs" "$out/artifacts" /work/logs /work/artifacts

set_stage()
{
    current_stage=$1
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$current_stage" >> /work/logs/stages.log
}

finalize()
{
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    mkdir -p "$out/logs" "$out/artifacts"
    printf '%s\n' "$status" > /work/logs/overall.exit
    printf '%s\n' "${current_stage:-unknown}" > /work/logs/last-stage.txt
    if [ -d /work/logs ]; then
        cp -a /work/logs/. "$out/logs/"
    fi
    if [ -d /work/artifacts ]; then
        cp -a /work/artifacts/. "$out/artifacts/"
    fi
    exit "$status"
}
trap finalize EXIT HUP INT TERM

set_stage install-dependencies
export DEBIAN_FRONTEND=noninteractive
set +e
{
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates curl make perl ripgrep git build-essential \
        debhelper-compat devscripts dpkg-dev dh-dkms dkms quilt xz-utils \
        linux-headers-amd64 lintian libvulkan1 po-debconf libglvnd-dev \
        libxext6 kmod file
} > /work/logs/dependencies.log 2>&1
dependency_status=$?
set -e
cat /work/logs/dependencies.log
test "$dependency_status" -eq 0
dpkg-query -W git gcc linux-headers-amd64 dkms dh-dkms dpkg-dev devscripts > /work/logs/dependency-versions.txt

set_stage validate-repository
test -d "$repository"
test -d "$repository/.git"
test -f "$repository/debian/changelog"
test -f "$repository/debian/rules"
git config --global --add safe.directory "$repository"
git config --global --get-all safe.directory > /work/logs/git-safe-directories.txt
git -C "$repository" status --porcelain > /work/logs/repository-status.txt
test ! -s /work/logs/repository-status.txt

set_stage create-repository-archive
mkdir -p /work/packaging /work/import /work/source-package /work/binary-source
repository_archive=/work/repository.tar
git -C "$repository" archive --format=tar --output="$repository_archive" HEAD
test -s "$repository_archive"
tar -tf "$repository_archive" > /work/logs/repository-archive-contents.txt
tar -xf "$repository_archive" -C /work/packaging
test -f /work/packaging/debian/changelog
test -f /work/packaging/debian/rules
test -x /work/packaging/debian/scripts/fetch-367.134-runfile

set_stage fetch-runfile
set +e
/work/packaging/debian/scripts/fetch-367.134-runfile /work/import /work > /work/logs/fetch.log 2>&1
fetch_status=$?
set -e
cat /work/logs/fetch.log
printf '%s\n' "$fetch_status" > /work/logs/fetch.exit
test "$fetch_status" -eq 0

set_stage verify-orig
test -s "/work/$main_orig"
test -s "/work/$amd64_orig"
file "/work/$main_orig" "/work/$amd64_orig" > /work/logs/orig-file-types.txt
xz -t < "/work/$main_orig"
xz -t < "/work/$amd64_orig"
tar -tf "/work/$main_orig" > /work/logs/main-orig-contents.txt
tar -tf "/work/$amd64_orig" > /work/logs/amd64-orig-contents.txt
grep -Fx "${source}-${version}/" /work/logs/main-orig-contents.txt
test "$(wc -l < /work/logs/main-orig-contents.txt)" -eq 1
if grep -E 'NVIDIA-Linux-.*\.run|\.ko(\..*)?$|\.so(\..*)?$' /work/logs/main-orig-contents.txt; then
    echo "primary orig unexpectedly contains proprietary payload" >&2
    exit 1
fi
grep -Fx "amd64/$runfile" /work/logs/amd64-orig-contents.txt
sha256sum "/work/$main_orig" > /work/logs/main-orig.sha256
sha256sum "/work/$amd64_orig" > /work/logs/amd64-orig.sha256
find "/work/import/NVIDIA-Linux-x86_64-$version" -type f -printf '%P\n' | sort > /work/logs/inventory-367.134.txt

cd /work/packaging
tests/no-390xx-leaks.sh
tests/amd64-only.sh
tests/no-proprietary-artifacts.sh
tests/generated-control-drift.sh

set_stage source-build
set +e
dpkg-buildpackage -us -uc -S > /work/logs/source-build.log 2>&1
source_status=$?
set -e
cat /work/logs/source-build.log
printf '%s\n' "$source_status" > /work/logs/source-build.exit
test "$source_status" -eq 0

find /work -maxdepth 1 -type f -name "${source}_*.dsc" -print > /work/logs/dsc-files.txt
dsc_count=$(wc -l < /work/logs/dsc-files.txt)
if [ "$dsc_count" -ne 1 ]; then
    echo "expected exactly one .dsc, found $dsc_count" >&2
    cat /work/logs/dsc-files.txt >&2
    exit 1
fi
dsc=$(cat /work/logs/dsc-files.txt)
test -f "$dsc"
find /work -maxdepth 1 -type f \( -name '*.dsc' -o -name '*.debian.tar.*' -o -name '*.orig*.tar.*' -o -name '*.changes' -o -name '*.buildinfo' \) -printf '%f\n' | sort > /work/logs/source-package-list.txt

set_stage source-extract
rm -rf /work/binary-source
set +e
dpkg-source -x "$dsc" /work/binary-source > /work/logs/source-extract.log 2>&1
extract_status=$?
set -e
cat /work/logs/source-extract.log
printf '%s\n' "$extract_status" > /work/logs/source-extract.exit
test "$extract_status" -eq 0
test -f "/work/binary-source/amd64/$runfile"
printf '%s  %s\n' "$sha256" "/work/binary-source/amd64/$runfile" | sha256sum -c -

cd /work/binary-source
stat -c '%A %a %n' \
    tests/no-390xx-leaks.sh \
    tests/amd64-only.sh \
    tests/generated-control-drift.sh \
    > /work/logs/extracted-script-modes.txt
cat /work/logs/extracted-script-modes.txt
sh tests/no-390xx-leaks.sh
sh tests/amd64-only.sh
sh tests/generated-control-drift.sh

set_stage binary-build
set +e
dpkg-buildpackage -us -uc -b > /work/logs/binary-build.log 2>&1
binary_status=$?
set -e
cat /work/logs/binary-build.log
printf '%s\n' "$binary_status" > /work/logs/binary-build.exit

find /work/binary-source -type f -name '*.rej' -print > /work/logs/quilt-reject-files.txt || true
{
    QUILT_PATCHES=debian/patches QUILT_SERIES=series-postunpack quilt applied 2>&1 || true
    echo '--- unapplied ---'
    QUILT_PATCHES=debian/patches QUILT_SERIES=series-postunpack quilt unapplied 2>&1 || true
} > /work/logs/quilt-state.txt
: > /work/logs/quilt-reject-contents.txt
while IFS= read -r reject; do
    test -n "$reject" || continue
    {
        printf '\n===== %s =====\n' "$reject"
        cat "$reject"
    } >> /work/logs/quilt-reject-contents.txt
done < /work/logs/quilt-reject-files.txt

grep -n -E 'kernel-source-tree|CC \[M\]|CONFTEST|nvidia-uvm|nvidia-drm|nvidia-modeset|nv-linux' /work/logs/binary-build.log > /work/logs/kernel-build-progress.txt || true
if test -s /work/logs/kernel-build-progress.txt; then
    echo yes > /work/logs/kernel-compilation-reached.txt
else
    echo no > /work/logs/kernel-compilation-reached.txt
fi
grep -n -C 8 -E 'error:|fatal error:|implicit declaration|incompatible pointer|No such file|treated as errors' /work/logs/binary-build.log > /work/logs/kernel-build-excerpt.txt || true

set_stage collect-results
find /work -maxdepth 1 -type f \( -name '*.deb' -o -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' \) -printf '%f\n' | sort > /work/logs/binary-package-list.txt
find /work -maxdepth 1 -type f \( -name '*.deb' -o -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' \) -exec cp -v {} /work/artifacts/ \; >> /work/logs/binary-package-list.txt || true

exit "$binary_status"
