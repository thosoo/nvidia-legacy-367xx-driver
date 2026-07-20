#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch="$repo/debian/module/debian/patches/backport-linux-ioctl32-header.patch"
test -f "$patch"
grep -F 'NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL' "$patch" >/dev/null
if awk '
    /^\+#if defined\(NVCPU_X86_64\) &&/ { guard=1; next }
    /^\+  !defined\(NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL\)/ && guard == 1 { guard=2; next }
    /^\+#endif/ && guard == 2 { guard=0; next }
    /^\+#include <linux\/ioctl32\.h>/ && guard != 2 { print; bad=1 }
    END { exit bad }
' "$patch"; then
    :
else
    echo "linux/ioctl32.h include is not guarded by NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL" >&2
    exit 1
fi
if find "$repo" -type l -path '*/linux/ioctl32.h' -print | grep . >/dev/null; then
    echo "fake linux/ioctl32.h symlink must not be created" >&2
    exit 1
fi
if find "$repo" -type f -path '*/linux/ioctl32.h' -print | grep . >/dev/null; then
    echo "fake linux/ioctl32.h file must not be created" >&2
    exit 1
fi
# Active patch additions/context must not add unconditional legacy registration.
if sed 's/#HAS_UVM#//g' "$repo/debian/module/debian/patches/series.in" |
    sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' |
    while IFS= read -r active_patch; do
        awk -v patch="$active_patch" '
            /^\+#if/ { guard=$0 }
            /^\+#endif/ { guard="" }
            /^\+/ && /(register_ioctl32_conversion|unregister_ioctl32_conversion)/ && guard !~ /NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL|NV_NEEDS_COMPAT_IOCTL_REGISTRATION/ {
                print patch ":" $0
            }
        ' "$repo/debian/module/debian/patches/$active_patch"
    done | grep . >/tmp/linux-ioctl32-unconditional.$$; then
    cat /tmp/linux-ioctl32-unconditional.$$ >&2
    rm -f /tmp/linux-ioctl32-unconditional.$$
    exit 1
fi
rm -f /tmp/linux-ioctl32-unconditional.$$
# Modern branch: with compat_ioctl present, neither header nor manual functions are selected.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/check-modern.c" <<'CHECKEOF'
#define NVCPU_X86_64 1
#define NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL 1
#if defined(NVCPU_X86_64) && \
  !defined(NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL)
#include <linux/syscalls.h>
#include <linux/ioctl32.h>
int x = (int)(long)register_ioctl32_conversion;
int y = (int)(long)unregister_ioctl32_conversion;
#endif
int ok;
CHECKEOF
${CC:-cc} -E "$tmp/check-modern.c" > "$tmp/modern.i"
if grep -E 'linux/ioctl32|register_ioctl32_conversion|unregister_ioctl32_conversion' "$tmp/modern.i" >/dev/null; then
    echo "modern compat_ioctl path still selects legacy ioctl32 registration" >&2
    exit 1
fi
# Legacy branch: without the compat_ioctl macro, the guarded block is selected.
cat > "$tmp/check-legacy.c" <<'CHECKEOF'
#define NVCPU_X86_64 1
#if defined(NVCPU_X86_64) && \
  !defined(NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL)
legacy_path_selected
#endif
CHECKEOF
${CC:-cc} -E "$tmp/check-legacy.c" > "$tmp/legacy.i"
grep -F 'legacy_path_selected' "$tmp/legacy.i" >/dev/null
