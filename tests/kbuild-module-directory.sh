#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
parent="$tmp/parent"
module_dir="$parent/kernel-source-tree"
kernel_dir="$tmp/kernel"
mkdir -p "$module_dir" "$kernel_dir"
cat > "$kernel_dir/Makefile" <<'MAKEEOF'
modules:
	@printf '%s\n' "KBUILD M=$(M)"
MAKEEOF
cat > "$module_dir/Makefile.in" <<'MAKEEOF'
KERNEL_SOURCES := @KERNEL_DIR@
KBUILD_PARAMS += -C $(KERNEL_SOURCES) M=$(CURDIR)
modules:
	@$(MAKE) $(KBUILD_PARAMS) modules
MAKEEOF
sed "s#@KERNEL_DIR@#$kernel_dir#" "$module_dir/Makefile.in" > "$module_dir/Makefile"
(
    cd "$parent"
    PWD="$parent" make -C kernel-source-tree modules
) > "$tmp/output.txt"
expected="KBUILD M=$module_dir"
wrong="KBUILD M=$parent"
grep -Fx "$expected" "$tmp/output.txt" >/dev/null
if grep -Fx "$wrong" "$tmp/output.txt" >/dev/null; then
    echo "Kbuild M= used caller PWD instead of module CURDIR" >&2
    cat "$tmp/output.txt" >&2
    exit 1
fi
grep -F 'M=$(CURDIR)' "$repo/debian/module/debian/patches/use-kbuild-module-directory.patch" >/dev/null
if sed 's/#HAS_UVM#//g' "$repo/debian/module/debian/patches/series.in" |
    sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' |
    while IFS= read -r patch; do
        sed -n '/^[+ ][^+]/p' "$repo/debian/module/debian/patches/$patch"
    done | grep -F 'M=$(PWD)' >/dev/null; then
    echo "active module patch leaves a non-removed M=\$(PWD) assignment" >&2
    exit 1
fi
