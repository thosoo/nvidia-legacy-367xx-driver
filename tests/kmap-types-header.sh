#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch="$repo/debian/module/debian/patches/backport-asm-kmap_types-header.patch"
test -f "$patch"
grep -F 'LINUX_VERSION_CODE < KERNEL_VERSION(5, 11, 0)' "$patch" >/dev/null
grep -F '#include <asm/kmap_types.h>' "$patch" >/dev/null
if grep -F 'RHEL_MAJOR' "$patch" >/dev/null; then
    echo "RHEL-specific kmap_types conditional must not be imported" >&2
    exit 1
fi
if find "$repo" -type l -path '*/asm/kmap_types.h' -print | grep . >/dev/null; then
    echo "fake asm/kmap_types.h symlink must not be created" >&2
    exit 1
fi
if find "$repo" -type f -path '*/asm/kmap_types.h' -print | grep . >/dev/null; then
    echo "fake asm/kmap_types.h file must not be created" >&2
    exit 1
fi
if awk '
    /^\+#if LINUX_VERSION_CODE < KERNEL_VERSION\(5, 11, 0\)/ { guard=1; next }
    /^\+#endif/ && guard == 1 { guard=0; next }
    /^\+#include <asm\/kmap_types\.h>/ && guard != 1 { print; bad=1 }
    END { exit bad }
' "$patch"; then
    :
else
    echo "asm/kmap_types.h include is not guarded for Linux < 5.11" >&2
    exit 1
fi
# Verify target kernel versions choose the omitted branch.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/check.c" <<'CHECKEOF'
#define KERNEL_VERSION(a,b,c) (((a) << 16) + ((b) << 8) + (c))
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 11, 0)
#error "asm/kmap_types.h branch selected"
#endif
int ok;
CHECKEOF
${CC:-cc} -DLINUX_VERSION_CODE=0x060100 -c "$tmp/check.c" -o "$tmp/bookworm.o"
${CC:-cc} -DLINUX_VERSION_CODE=0x060c00 -c "$tmp/check.c" -o "$tmp/trixie.o"
