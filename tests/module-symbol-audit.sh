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
0x2 gpl_symbol vmlinux EXPORT_SYMBOL_GPL
0x3 prefix vmlinux EXPORT_SYMBOL
0x4 prefix_extra vmlinux EXPORT_SYMBOL
SYMS
cat > "$tmp/nm-ok" <<'NM'
#!/bin/sh
case "$1" in
    --version) echo 'GNU nm fixture'; exit 0 ;;
    -u) shift ;;
esac
cat <<OUT
normal_symbol U
prefix_extra U
weak_symbol w
OUT
NM
chmod +x "$tmp/nm-ok"
PATH="$tmp:$PATH" NM=nm-ok tools/audit-module-symbols.sh "$tmp/mods" "$tmp/headers" "$tmp/out-ok"
test -s "$tmp/out-ok/nvidia.workqueue-symbols.txt" || test -f "$tmp/out-ok/nvidia.workqueue-symbols.txt"
cat > "$tmp/nm-missing" <<'NM'
#!/bin/sh
case "$1" in --version) echo fixture; exit 0 ;; -u) shift ;; esac
echo 'missing_symbol U'
NM
chmod +x "$tmp/nm-missing"
if PATH="$tmp:$PATH" NM=nm-missing tools/audit-module-symbols.sh "$tmp/mods" "$tmp/headers" "$tmp/out-missing" >/dev/null 2>&1; then
    echo 'missing symbol unexpectedly accepted' >&2
    exit 1
fi
cat > "$tmp/nm-gpl" <<'NM'
#!/bin/sh
case "$1" in --version) echo fixture; exit 0 ;; -u) shift ;; esac
echo 'gpl_symbol U'
NM
chmod +x "$tmp/nm-gpl"
if PATH="$tmp:$PATH" NM=nm-gpl tools/audit-module-symbols.sh "$tmp/mods" "$tmp/headers" "$tmp/out-gpl" >/dev/null 2>&1; then
    echo 'GPL-only symbol unexpectedly accepted' >&2
    exit 1
fi
