#!/bin/sh
set -eu
repo=$(readlink -f "${1:-.}")
out=$(readlink -m "${2:-ubuntu-6.8-results}")
mkdir -p "$out/logs" "$out/symbols"
headers=$(find /usr/src -maxdepth 1 -type d -name 'linux-headers-6.8.*-generic' | sort | tail -n 1)
if [ -z "$headers" ]; then
    echo "no Ubuntu 6.8 generic headers found" >&2
    exit 1
fi
kernel=${headers#/usr/src/linux-headers-}
case "$kernel" in
    6.8.*-generic) ;;
    *) echo "unexpected kernel release: $kernel" >&2; exit 1 ;;
esac
printf '%s\n' "$kernel" > "$out/logs/kernel-release.txt"
cc --version | sed -n '1p' > "$out/logs/compiler.txt"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
prepared=$("$repo/tools/prepare-kernel-tree.sh" bookworm "$tmp")
series_file=$tmp/module-series.txt
sed 's/#HAS_UVM#//g' "$repo/debian/module/debian/patches/series.in" | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' > "$series_file"
while IFS= read -r patch; do
    patch -d "$prepared" -p1 --no-backup-if-mismatch -i "$repo/debian/module/debian/patches/$patch" >> "$out/logs/quilt-apply.log" 2>&1
done < "$series_file"
if find "$prepared" \( -name '*.rej' -o -name '*.orig' \) | grep . > "$out/logs/reject-orig-files.txt"; then
    cat "$out/logs/reject-orig-files.txt" >&2
    exit 1
fi
set +e
"$repo/tools/compile-kernel-tree.sh" "$prepared" "$kernel" > "$out/logs/compile.log" 2>&1
status=$?
set -e
cat "$out/logs/compile.log"
printf '%s\n' "$status" > "$out/logs/compile.exit"
test "$status" -eq 0
for mod in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
    test -s "$prepared/$mod.ko"
    printf yes > "$out/logs/$mod-ko-created.txt"
done
test -s "$prepared/modules.order"
test -s "$headers/Module.symvers"
test -s "$prepared/Module.symvers"
printf yes > "$out/logs/modules-order-created.txt"
printf yes > "$out/logs/module-symvers-created.txt"
if grep -Eq '(^|[[:space:]])MODPOST([[:space:]]|$)|scripts/Makefile\.modpost' "$out/logs/compile.log" || test -s "$prepared/Module.symvers"; then
    printf yes > "$out/logs/modpost-reached.txt"
else
    printf no > "$out/logs/modpost-reached.txt"
    exit 1
fi
sh "$repo/tools/audit-module-symbols.sh" "$prepared" "$headers/Module.symvers" "$prepared/Module.symvers" "$out/symbols" > "$out/logs/symbol-audit.log" 2>&1
cat "$out/logs/symbol-audit.log"
