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

run_repository_test()
{
    name=$1
    shift

    set +e
    "$@" > "/work/logs/test-${name}.log" 2>&1
    status=$?
    set -e

    cat "/work/logs/test-${name}.log"
    printf '%s\n' "$status" > "/work/logs/test-${name}.exit"
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$name" > /work/logs/failed-repository-test.txt
        return "$status"
    fi
}

set_stage repository-tests
run_repository_test no-390xx-leaks tests/no-390xx-leaks.sh
run_repository_test no-390xx-leaks-regression tests/no-390xx-leaks-regression.sh
run_repository_test amd64-only tests/amd64-only.sh
run_repository_test no-proprietary-artifacts tests/no-proprietary-artifacts.sh
run_repository_test generated-control-drift tests/generated-control-drift.sh
run_repository_test license-367xx tests/license-367xx.sh
run_repository_test supported-pci-ids tests/supported-pci-ids.sh
run_repository_test vmalloc-signature tests/vmalloc-signature.sh
run_repository_test ioremap-nocache tests/ioremap-nocache.sh
run_repository_test smp-call-return-type tests/smp-call-return-type.sh
run_repository_test swiotlb-detection tests/swiotlb-detection.sh
run_repository_test sg-allocation-conftest tests/sg-allocation-conftest.sh
run_repository_test acpi-api-compat tests/acpi-api-compat.sh
run_repository_test dma-mask-api tests/dma-mask-api.sh
run_repository_test procfs-api-compat tests/procfs-api-compat.sh
run_repository_test timekeeping-api-compat tests/timekeeping-api-compat.sh
run_repository_test scheduler-state-api tests/scheduler-state-api.sh
run_repository_test mmap-lock-api tests/mmap-lock-api.sh
run_repository_test uvm-mmap-lock-api tests/uvm-mmap-lock-api.sh
run_repository_test uvm-vm-fault-api tests/uvm-vm-fault-api.sh
run_repository_test uvm-dependency-barrier tests/uvm-dependency-barrier.sh
run_repository_test uvm-interface-header-order tests/uvm-interface-header-order.sh
run_repository_test drm-preprocessor-balance-fixtures tests/drm-preprocessor-balance.sh
run_repository_test userspace-manifest-inventory-fixtures tests/userspace-manifest-inventory.sh
run_repository_test module-build-diagnostics tests/module-build-diagnostics.sh
run_repository_test userspace-manifest-inventory tests/userspace-manifest-inventory.sh "/work/import/NVIDIA-Linux-x86_64-$version"

set_stage module-series-integrity
module_integrity_tree=$(tools/prepare-kernel-tree.sh "$suite" /work/module-series-integrity)
printf '%s\n' "$module_integrity_tree" > /work/logs/module-series-integrity-tree.txt
run_repository_test module-patch-integrity-pr5 tests/module-patch-integrity.sh "$module_integrity_tree"
run_repository_test module-patch-integrity-full tests/module-patch-integrity.sh --full-series "$module_integrity_tree"
run_repository_test patch-series-position tests/patch-series-position.sh "$module_integrity_tree"
run_repository_test drm-preprocessor-balance tests/drm-preprocessor-balance.sh "$module_integrity_tree"
run_repository_test uvm-mmap-lock-api-series tests/uvm-mmap-lock-api.sh "$module_integrity_tree"

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

set +e
: > /work/logs/post-build-diagnostics-failures.txt
{
    PS4='+diagnostics: '
    set -x

    find /work/binary-source -type f -name '*.rej' -print > /work/logs/quilt-reject-files.txt || \
        echo "find quilt rejects failed" >> /work/logs/post-build-diagnostics-failures.txt
    # Capture production module quilt rejects before running audit replay.
    sh /work/binary-source/tools/collect-module-rejects.sh \
        /work/binary-source \
        /work/logs || echo "collect module rejects before audit failed" >> /work/logs/post-build-diagnostics-failures.txt
    if test -d /work/binary-source/build/kernel; then
        sh /work/binary-source/tools/audit-module-series.sh \
            /work/binary-source/build/kernel \
            /work/logs/module-patch-audit || echo "module series audit failed" >> /work/logs/post-build-diagnostics-failures.txt
    fi
    if test -d /work/binary-source/kernel-source-tree; then
        (
            cd /work/binary-source/kernel-source-tree || exit
            QUILT_PATCHES=../debian/module/debian/patches quilt applied 2>&1 || true
        ) > /work/logs/module-quilt-applied.txt
        (
            cd /work/binary-source/kernel-source-tree || exit
            QUILT_PATCHES=../debian/module/debian/patches quilt unapplied 2>&1 || true
        ) > /work/logs/module-quilt-unapplied.txt
    else
        echo "kernel-source-tree not created" > /work/logs/module-quilt-applied.txt
        echo "kernel-source-tree not created" > /work/logs/module-quilt-unapplied.txt
    fi
    cat /work/logs/module-quilt-applied.txt /work/logs/module-quilt-unapplied.txt > /work/logs/module-quilt-state.txt
    if grep -qi 'fully applied' /work/logs/module-quilt-unapplied.txt; then
        echo yes > /work/logs/module-quilt-series-complete.txt
        echo none > /work/logs/module-quilt-failed-patch.txt
    else
        echo no > /work/logs/module-quilt-series-complete.txt
        awk 'NF { print; exit }' /work/logs/module-quilt-unapplied.txt \
            > /work/logs/module-quilt-failed-patch.txt || true
        test -s /work/logs/module-quilt-failed-patch.txt || echo none > /work/logs/module-quilt-failed-patch.txt
    fi
    # Refresh the reject snapshot after recording quilt state, without depending on
    # audit-generated reject files.
    sh /work/binary-source/tools/collect-module-rejects.sh \
        /work/binary-source \
        /work/logs || echo "collect module rejects after quilt state failed" >> /work/logs/post-build-diagnostics-failures.txt
    if test -f /work/binary-source/copyright.tmp && test -f /work/binary-source/LICENSE.tmp; then
        diff -w /work/binary-source/copyright.tmp /work/binary-source/LICENSE.tmp \
            > /work/logs/license-comparison-excerpt.txt || true
    fi
    (
        cd /work/binary-source || exit
        QUILT_PATCHES=debian/patches QUILT_SERIES=series-postunpack quilt applied 2>&1 || true
        echo '--- unapplied ---'
        QUILT_PATCHES=debian/patches QUILT_SERIES=series-postunpack quilt unapplied 2>&1 || true
    ) > /work/logs/quilt-state.txt
    : > /work/logs/quilt-reject-contents.txt
    while IFS= read -r reject; do
        test -n "$reject" || continue
        {
            printf '\n===== %s =====\n' "$reject"
            cat "$reject"
        } >> /work/logs/quilt-reject-contents.txt
    done < /work/logs/quilt-reject-files.txt

    grep -n -E 'kernel-source-tree|CC \[M\]|LD \[M\]|MODPOST|CONFTEST|nvidia-uvm|nvidia-drm|nvidia-modeset|nv-linux|make .* -C /lib/modules' /work/logs/binary-build.log > /work/logs/kernel-build-progress.txt || true
    grep -n -C 50 -E 'error:|fatal error:|implicit declaration|incompatible pointer|No such file|treated as errors' /work/logs/binary-build.log > /work/logs/kernel-build-excerpt.txt || true

    module_source=/work/binary-source/kernel-source-tree
    printf '%s\n' /work/binary-source > /work/logs/module-make-caller-pwd.txt
    printf '%s\n' "$module_source" > /work/logs/module-make-caller-curdir.txt
    printf '%s\n' "$module_source" > /work/logs/module-make-source-directory.txt
    grep -m1 -E 'make .* -C /lib/modules|/usr/bin/make .* -C /lib/modules' /work/logs/binary-build.log > /work/logs/module-kbuild-command.txt || true
    sed -n 's/.*[[:space:]]M=\([^[:space:]]*\).*/\1/p' /work/logs/module-kbuild-command.txt | head -n 1 > /work/logs/module-kbuild-M-value.txt || true
    test -s /work/logs/module-kbuild-M-value.txt || echo unknown > /work/logs/module-kbuild-M-value.txt
    if grep -Fx /work/binary-source /work/logs/module-kbuild-M-value.txt >/dev/null; then
        echo "module Kbuild M= points at package root instead of kernel-source-tree" >> /work/logs/post-build-diagnostics-failures.txt
    fi
    if test -d "$module_source"; then
        echo yes > /work/logs/kernel-source-tree-created.txt
    else
        echo no > /work/logs/kernel-source-tree-created.txt
    fi
    if grep -qi 'fully applied' /work/logs/module-quilt-unapplied.txt; then
        echo yes > /work/logs/module-series-applied.txt
    else
        echo no > /work/logs/module-series-applied.txt
    fi
    if grep -Eq 'make .* -C /lib/modules/.*/(build|source)|/usr/bin/make .* -C /lib/modules' /work/logs/binary-build.log; then
        echo yes > /work/logs/kernel-kbuild-invoked.txt
    else
        echo no > /work/logs/kernel-kbuild-invoked.txt
    fi
    if grep -Eq '(^|[[:space:]])CC[[:space:]]+\[M\]' /work/logs/binary-build.log || \
       { grep -Eq 'kernel-source-tree/.*/(nvidia|nvidia-modeset|nvidia-drm|nvidia-uvm)/[^[:space:]]+\.c' /work/logs/binary-build.log && \
         grep -Eq '[[:space:]]-c[[:space:]]' /work/logs/binary-build.log && \
         grep -Eq '[[:space:]]-o[[:space:]][^[:space:]]*kernel-source-tree/(nvidia|nvidia-modeset|nvidia-drm|nvidia-uvm)/[^[:space:]]+\.o' /work/logs/binary-build.log; }; then
        echo yes > /work/logs/module-c-compiler-reached.txt
    else
        echo no > /work/logs/module-c-compiler-reached.txt
    fi
    for module_name in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
        if test -s "$module_source/${module_name}.ko"; then
            echo yes > "/work/logs/${module_name}-ko-created.txt"
        else
            echo no > "/work/logs/${module_name}-ko-created.txt"
        fi
    done
    if test -s "$module_source/modules.order"; then
        echo yes > /work/logs/modules-order-created.txt
    else
        echo no > /work/logs/modules-order-created.txt
    fi
    if test -s "$module_source/Module.symvers"; then
        echo yes > /work/logs/module-symvers-created.txt
    else
        echo no > /work/logs/module-symvers-created.txt
    fi
    if grep -Eq '(^|[[:space:]])LD[[:space:]]+\[M\]|ld[[:space:]].*-o[[:space:]][^[:space:]]*kernel-source-tree/(nvidia|nvidia-modeset|nvidia-drm|nvidia-uvm)\.ko' /work/logs/binary-build.log || \
       grep -qx yes /work/logs/nvidia-ko-created.txt && grep -qx yes /work/logs/nvidia-modeset-ko-created.txt && grep -qx yes /work/logs/nvidia-drm-ko-created.txt && grep -qx yes /work/logs/nvidia-uvm-ko-created.txt; then
        echo yes > /work/logs/module-linker-reached.txt
    else
        echo no > /work/logs/module-linker-reached.txt
    fi
    if grep -Eq '(^|[[:space:]])MODPOST([[:space:]]|$)|scripts/Makefile\.modpost' /work/logs/binary-build.log || test -s "$module_source/Module.symvers"; then
        echo yes > /work/logs/modpost-reached.txt
    else
        echo no > /work/logs/modpost-reached.txt
    fi
    if grep -qx yes /work/logs/nvidia-ko-created.txt && grep -qx yes /work/logs/nvidia-modeset-ko-created.txt && \
       grep -qx yes /work/logs/nvidia-drm-ko-created.txt && grep -qx yes /work/logs/nvidia-uvm-ko-created.txt && \
       grep -qx yes /work/logs/modules-order-created.txt; then
        echo yes > /work/logs/kernel-module-build-complete.txt
    else
        echo no > /work/logs/kernel-module-build-complete.txt
    fi
    printf '%s\n' "$suite" > /work/logs/kernel-module-build-suite.txt
    if grep -Eq '(^|[[:space:]])dh_install([[:space:]]|$)|override_dh_install|debian/rules binary' /work/logs/binary-build.log; then
        echo yes > /work/logs/dh-install-command-reached.txt
        echo yes > /work/logs/dh-install-reached.txt
    else
        echo no > /work/logs/dh-install-command-reached.txt
        echo no > /work/logs/dh-install-reached.txt
    fi
    if grep -Eq '(^|[[:space:]])dh_missing([[:space:]]|$)|--fail-missing|fail-missing' /work/logs/binary-build.log; then
        echo yes > /work/logs/dh-missing-reached.txt
        echo yes > /work/logs/binary-packaging-reached.txt
    else
        echo no > /work/logs/dh-missing-reached.txt
        echo no > /work/logs/binary-packaging-reached.txt
    fi
    sed -n '/dh_missing/,$p' /work/logs/binary-build.log > /work/logs/dh-missing.log || true
    awk '
        /The following files are not installed/ { capture=1; next }
        capture && /^$/ { capture=0 }
        capture && $0 !~ /^dh_missing/ && $0 !~ /^	/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if ($0 != "") print $0
        }
    ' /work/logs/binary-build.log > /work/logs/dh-missing-unowned-files.txt || true
    if grep -Eq 'dh_install: error|dh_install:.*missing|cannot stat' /work/logs/binary-build.log; then
        echo no > /work/logs/dh-install-command-complete.txt
    elif grep -qx yes /work/logs/dh-install-command-reached.txt && { grep -qx yes /work/logs/dh-missing-reached.txt || [ "$binary_status" -eq 0 ]; }; then
        echo yes > /work/logs/dh-install-command-complete.txt
    elif grep -qx yes /work/logs/dh-install-command-reached.txt; then
        echo unknown > /work/logs/dh-install-command-complete.txt
    else
        echo unknown > /work/logs/dh-install-command-complete.txt
    fi
    cp /work/logs/dh-install-command-complete.txt /work/logs/dh-install-complete.txt
    if grep -qx yes /work/logs/dh-missing-reached.txt; then
        if grep -Eq 'dh_missing: error|not installed|missing files' /work/logs/binary-build.log || test -s /work/logs/dh-missing-unowned-files.txt; then
            echo 1 > /work/logs/dh-missing.exit
            echo no > /work/logs/dh-missing-complete.txt
        else
            echo 0 > /work/logs/dh-missing.exit
            echo yes > /work/logs/dh-missing-complete.txt
        fi
    else
        echo unknown > /work/logs/dh-missing.exit
        echo unknown > /work/logs/dh-missing-complete.txt
    fi
    if grep -Eq 'yes' /work/logs/module-c-compiler-reached.txt /work/logs/module-linker-reached.txt /work/logs/modpost-reached.txt; then
        echo yes > /work/logs/kernel-compilation-reached.txt
    else
        echo no > /work/logs/kernel-compilation-reached.txt
    fi
    if test -d "$module_source/conftest-sg-diagnostics"; then
        mkdir -p /work/logs/conftest-sg-diagnostics
        find "$module_source/conftest-sg-diagnostics" -type f \
            ! -name '*.o' ! -name '*.ko' ! -name '*.cmd' \
            -exec cp -v {} /work/logs/conftest-sg-diagnostics/ \; \
            > /work/logs/conftest-sg-diagnostics-files.txt 2>&1 || \
            echo "copy SG conftest diagnostics failed" >> /work/logs/post-build-diagnostics-failures.txt
    else
        echo "no SG conftest diagnostics directory" > /work/logs/conftest-sg-diagnostics-files.txt
    fi
    if test -d "$module_source/conftest-pci-dma-diagnostics"; then
        mkdir -p /work/logs/conftest-pci-dma-diagnostics
        find "$module_source/conftest-pci-dma-diagnostics" -type f \
            ! -name '*.o' ! -name '*.ko' ! -name '*.cmd' \
            -exec cp -v {} /work/logs/conftest-pci-dma-diagnostics/ \; \
            > /work/logs/conftest-pci-dma-diagnostics-files.txt 2>&1 || \
            echo "copy PCI DMA conftest diagnostics failed" >> /work/logs/post-build-diagnostics-failures.txt
    else
        echo "no PCI DMA conftest diagnostics directory" > /work/logs/conftest-pci-dma-diagnostics-files.txt
    fi
    if test -d "$module_source/conftest-procfs-diagnostics"; then
        mkdir -p /work/logs/conftest-procfs-diagnostics
        find "$module_source/conftest-procfs-diagnostics" -type f \
            ! -name '*.o' ! -name '*.ko' ! -name '*.cmd' \
            -exec cp -v {} /work/logs/conftest-procfs-diagnostics/ \; \
            > /work/logs/conftest-procfs-diagnostics-files.txt 2>&1 || \
            echo "copy procfs conftest diagnostics failed" >> /work/logs/post-build-diagnostics-failures.txt
    else
        echo "no procfs conftest diagnostics directory" > /work/logs/conftest-procfs-diagnostics-files.txt
    fi
    if test -d "$module_source/conftest-timekeeping-diagnostics"; then
        mkdir -p /work/logs/conftest-timekeeping-diagnostics
        find "$module_source/conftest-timekeeping-diagnostics" -type f \
            ! -name '*.o' ! -name '*.ko' ! -name '*.cmd' \
            -exec cp -v {} /work/logs/conftest-timekeeping-diagnostics/ \; \
            > /work/logs/conftest-timekeeping-diagnostics-files.txt 2>&1 || \
            echo "copy timekeeping conftest diagnostics failed" >> /work/logs/post-build-diagnostics-failures.txt
    else
        echo "no timekeeping conftest diagnostics directory" > /work/logs/conftest-timekeeping-diagnostics-files.txt
    fi
    if test -d "$module_source/conftest-dependency-barrier-diagnostics"; then
        mkdir -p /work/logs/conftest-dependency-barrier-diagnostics
        find "$module_source/conftest-dependency-barrier-diagnostics" -type f \
            ! -name '*.o' ! -name '*.ko' ! -name '*.cmd' \
            -exec cp -v {} /work/logs/conftest-dependency-barrier-diagnostics/ \; \
            > /work/logs/conftest-dependency-barrier-diagnostics-files.txt 2>&1 || \
            echo "copy dependency-barrier conftest diagnostics failed" >> /work/logs/post-build-diagnostics-failures.txt
    else
        echo "no dependency-barrier conftest diagnostics directory" > /work/logs/conftest-dependency-barrier-diagnostics-files.txt
    fi
    if test -e glvnd/nvidia_icd.json && test -e nonglvnd/nvidia_icd.json; then
        sh tests/vulkan-icd-json.sh . > /work/logs/vulkan-icd-json.log 2>&1
        vulkan_icd_status=$?
        cat /work/logs/vulkan-icd-json.log
        printf '%s\n' "$vulkan_icd_status" > /work/logs/vulkan-icd-json.exit
        if [ "$binary_status" -eq 0 ] && [ "$vulkan_icd_status" -ne 0 ]; then
            echo "vulkan ICD validation failed" >> /work/logs/post-build-diagnostics-failures.txt
        fi
    fi

    set_stage collect-results
    find /work -maxdepth 1 -type f \( -name '*.deb' -o -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' \) -printf '%f\n' | sort > /work/logs/binary-package-list.txt || \
        echo "binary package listing failed" >> /work/logs/post-build-diagnostics-failures.txt
    find /work -maxdepth 1 -type f \( -name '*.deb' -o -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' \) -exec cp -v {} /work/artifacts/ \; >> /work/logs/binary-package-list.txt || true
    set +x
} > /work/logs/post-build-diagnostics.trace.txt 2>&1
diagnostics_status=$?
printf '%s\n' "$diagnostics_status" > /work/logs/post-build-diagnostics.exit
set -e

exit "$binary_status"
