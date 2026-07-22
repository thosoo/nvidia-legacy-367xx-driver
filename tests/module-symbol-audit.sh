#!/bin/sh
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/bookworm.log" <<'LOG'
/usr/bin/make KBUILD_OUTPUT=/lib/modules/6.1.0-51-amd64/build NV_KERNEL_OUTPUT=/lib/modules/6.1.0-51-amd64/build -C /lib/modules/6.1.0-51-amd64/source M=/work/binary-source/kernel-source-tree modules
LOG
test "$(tools/extract-kernel-release.sh "$tmp/bookworm.log")" = 6.1.0-51-amd64
cat > "$tmp/trixie.log" <<'LOG'
/usr/bin/make KBUILD_OUTPUT=/lib/modules/6.12.96+deb13-amd64/build NV_KERNEL_OUTPUT=/lib/modules/6.12.96+deb13-amd64/build -C /lib/modules/6.12.96+deb13-amd64/source M=/work/binary-source/kernel-source-tree modules
LOG
test "$(tools/extract-kernel-release.sh "$tmp/trixie.log")" = 6.12.96+deb13-amd64
cat > "$tmp/conflict.log" <<'LOG'
/usr/bin/make KBUILD_OUTPUT=/lib/modules/6.1.0-51-amd64/build -C /lib/modules/6.12.96+deb13-amd64/source modules
LOG
if tools/extract-kernel-release.sh "$tmp/conflict.log" >/dev/null 2>&1; then
    echo 'conflicting releases unexpectedly accepted' >&2
    exit 1
fi
mkdir -p "$tmp/mods" "$tmp/headers"
printf 'dummy' > "$tmp/mods/nvidia.ko"
printf 'dummy' > "$tmp/mods/nvidia-modeset.ko"
printf 'dummy' > "$tmp/mods/nvidia-drm.ko"
printf 'dummy' > "$tmp/mods/nvidia-uvm.ko"
cat > "$tmp/headers/Module.symvers" <<'SYMS'
0x1 normal_symbol vmlinux EXPORT_SYMBOL
0x2 gpl_kernel vmlinux EXPORT_SYMBOL_GPL
0x3 prefix vmlinux EXPORT_SYMBOL
0x4 prefix_extra vmlinux EXPORT_SYMBOL
0x5 duplicate_same nvidia EXPORT_SYMBOL
0x6 duplicate_conflict vmlinux EXPORT_SYMBOL
SYMS
cat > "$tmp/mods/Module.symvers" <<'SYMS'
0x100 nvidia_get_rm_ops nvidia EXPORT_SYMBOL
0x101 nvUvmInterfaceRegisterGpu nvidia EXPORT_SYMBOL
0x5 duplicate_same nvidia EXPORT_SYMBOL
0x999 duplicate_conflict nvidia EXPORT_SYMBOL
0x200 gpl_sibling nvidia EXPORT_SYMBOL_GPL
SYMS
make_nm()
{
    path=$1
    shift
    {
        printf '%s\n' '#!/bin/sh'
        # shellcheck disable=SC2016
        printf '%s\n' 'case "$1" in --version) echo "GNU nm fixture"; exit 0 ;; -u) shift ;; esac'
        printf '%s\n' 'cat <<OUT'
        printf '%s\n' "$@"
        printf '%s\n' 'OUT'
    } > "$path"
    chmod +x "$path"
}
make_nm "$tmp/nm-ok" \
    'normal_symbol U' \
    'prefix_extra U' \
    'nvidia_get_rm_ops U' \
    'nvUvmInterfaceRegisterGpu U' \
    'duplicate_same U' \
    'weak_symbol w'
PATH="$tmp:$PATH" NM=nm-ok tools/audit-module-symbols.sh "$tmp/mods" "$tmp/headers/Module.symvers" "$tmp/mods/Module.symvers" "$tmp/out-ok"
awk '$1 == "nvidia_get_rm_ops" && $3 == "sibling-module" && $4 == "nvidia"' "$tmp/out-ok/nvidia-modeset.symbol-audit.txt" >/dev/null
awk '$1 == "nvUvmInterfaceRegisterGpu" && $3 == "sibling-module" && $4 == "nvidia"' "$tmp/out-ok/nvidia-uvm.symbol-audit.txt" >/dev/null
awk '$1 == "prefix_extra" && $4 == "vmlinux"' "$tmp/out-ok/nvidia.symbol-audit.txt" >/dev/null
grep -F 'weak_symbol w weak-undefined-not-required' "$tmp/out-ok/nvidia.symbol-audit.txt" >/dev/null
test -f "$tmp/out-ok/nvidia.workqueue-symbols.txt"
make_nm "$tmp/nm-missing" 'missing_symbol U'
if PATH="$tmp:$PATH" NM=nm-missing tools/audit-module-symbols.sh "$tmp/mods" "$tmp/headers/Module.symvers" "$tmp/mods/Module.symvers" "$tmp/out-missing" >/dev/null 2>&1; then
    echo 'missing symbol unexpectedly accepted' >&2
    exit 1
fi
make_nm "$tmp/nm-gpl-kernel" 'gpl_kernel U'
if PATH="$tmp:$PATH" NM=nm-gpl-kernel tools/audit-module-symbols.sh "$tmp/mods" "$tmp/headers/Module.symvers" "$tmp/mods/Module.symvers" "$tmp/out-gpl-kernel" >/dev/null 2>&1; then
    echo 'kernel GPL-only symbol unexpectedly accepted' >&2
    exit 1
fi
make_nm "$tmp/nm-gpl-sibling" 'gpl_sibling U'
if PATH="$tmp:$PATH" NM=nm-gpl-sibling tools/audit-module-symbols.sh "$tmp/mods" "$tmp/headers/Module.symvers" "$tmp/mods/Module.symvers" "$tmp/out-gpl-sibling" >/dev/null 2>&1; then
    echo 'sibling GPL-only symbol unexpectedly accepted' >&2
    exit 1
fi
make_nm "$tmp/nm-conflict" 'duplicate_conflict U'
if PATH="$tmp:$PATH" NM=nm-conflict tools/audit-module-symbols.sh "$tmp/mods" "$tmp/headers/Module.symvers" "$tmp/mods/Module.symvers" "$tmp/out-conflict" >/dev/null 2>&1; then
    echo 'conflicting duplicate symbol unexpectedly accepted' >&2
    exit 1
fi
