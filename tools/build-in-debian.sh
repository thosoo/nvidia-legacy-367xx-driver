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
    chmod -R a+rX /work/logs /work/artifacts
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

set_stage verify-supported-pci-ids
set +e
sh /work/packaging/tests/supported-pci-ids.sh \
    "/work/import/NVIDIA-Linux-x86_64-$version" \
    /work/logs/inventory-supported-pci-ids-367.134.txt \
    > /work/logs/supported-pci-ids.log 2>&1
pci_status=$?
set -e
cat /work/logs/supported-pci-ids.log
printf '%s\n' "$pci_status" > /work/logs/supported-pci-ids.exit
test "$pci_status" -eq 0

cd /work/packaging
tests/no-390xx-leaks.sh
tests/amd64-only.sh
tests/no-proprietary-artifacts.sh
tests/generated-control-drift.sh
tests/license-367xx.sh
tests/supported-pci-ids.sh

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
sh tests/license-367xx.sh
sh tests/supported-pci-ids.sh
if test -e glvnd/nvidia_icd.json || test -e nonglvnd/nvidia_icd.json; then
    test -e glvnd/nvidia_icd.json
    test -e nonglvnd/nvidia_icd.json
    sh tests/vulkan-icd-json.sh .
fi

set_stage binary-build
set +e
dpkg-buildpackage -us -uc -b > /work/logs/binary-build.log 2>&1
binary_status=$?
set -e
cat /work/logs/binary-build.log
printf '%s\n' "$binary_status" > /work/logs/binary-build.exit
if [ "$binary_status" -ne 0 ]; then
    printf '%s\n' "$current_stage" > /work/logs/failed-stage.txt
fi

find /work/binary-source -type f -name '*.rej' -print > /work/logs/quilt-reject-files.txt || true
if test -d /work/binary-source/build/kernel; then
    sh /work/binary-source/tools/audit-module-series.sh \
        /work/binary-source/build/kernel \
        /work/logs/module-patch-audit || true
fi
{
    if test -d /work/binary-source/kernel-source-tree; then
        cd /work/binary-source/kernel-source-tree
        QUILT_PATCHES=../debian/module/debian/patches quilt applied 2>&1 || true
    else
        echo "kernel-source-tree not created"
    fi
} > /work/logs/module-quilt-applied.txt
{
    if test -d /work/binary-source/kernel-source-tree; then
        cd /work/binary-source/kernel-source-tree
        QUILT_PATCHES=../debian/module/debian/patches quilt unapplied 2>&1 || true
    else
        echo "kernel-source-tree not created"
    fi
} > /work/logs/module-quilt-unapplied.txt
cat /work/logs/module-quilt-applied.txt /work/logs/module-quilt-unapplied.txt > /work/logs/module-quilt-state.txt
find /work/binary-source/kernel-source-tree -type f -name '*.rej' -print > /work/logs/module-quilt-reject-files.txt 2>/dev/null || true
: > /work/logs/module-quilt-reject-contents.txt
while IFS= read -r reject; do
    test -n "$reject" || continue
    {
        printf '\n===== %s =====\n' "$reject"
        cat "$reject"
    } >> /work/logs/module-quilt-reject-contents.txt
done < /work/logs/module-quilt-reject-files.txt
if test -f /work/binary-source/copyright.tmp && test -f /work/binary-source/LICENSE.tmp; then
    diff -w /work/binary-source/copyright.tmp /work/binary-source/LICENSE.tmp \
        > /work/logs/license-comparison-excerpt.txt || true
fi
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
if test -d /work/binary-source/kernel-source-tree; then
    echo yes > /work/logs/kernel-source-tree-created.txt
else
    echo no > /work/logs/kernel-source-tree-created.txt
fi
if test -d /work/binary-source/kernel-source-tree &&
   grep -Eq '(^|[[:space:]])(CC|LD)[[:space:]]+\[M\]|MODPOST|make .* -C /lib/modules/.*/build' /work/logs/binary-build.log
then
    echo yes > /work/logs/kernel-compilation-reached.txt
else
    echo no > /work/logs/kernel-compilation-reached.txt
fi
grep -n -C 8 -E 'error:|fatal error:|implicit declaration|incompatible pointer|No such file|treated as errors' /work/logs/binary-build.log > /work/logs/kernel-build-excerpt.txt || true
if test -e glvnd/nvidia_icd.json && test -e nonglvnd/nvidia_icd.json; then
    set +e
    sh tests/vulkan-icd-json.sh . > /work/logs/vulkan-icd-json.log 2>&1
    vulkan_icd_status=$?
    set -e
    cat /work/logs/vulkan-icd-json.log
    printf '%s\n' "$vulkan_icd_status" > /work/logs/vulkan-icd-json.exit
    if [ "$binary_status" -eq 0 ]; then
        test "$vulkan_icd_status" -eq 0
    fi
fi

set_stage collect-results
find /work -maxdepth 1 -type f \( -name '*.deb' -o -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' \) -printf '%f\n' | sort > /work/logs/binary-package-list.txt
find /work -maxdepth 1 -type f \( -name '*.deb' -o -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' \) -exec cp -v {} /work/artifacts/ \; >> /work/logs/binary-package-list.txt || true

exit "$binary_status"
