#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch="$repo/debian/module/debian/patches/backport-linux-standard-headers.patch"
test -f "$patch"
grep -F 'common/inc/nv_stdarg.h' "$patch" >/dev/null
grep -F 'common/inc/nv_stddef.h' "$patch" >/dev/null
grep -F '#include <linux/stdarg.h>' "$patch" >/dev/null
grep -F '#include <linux/stddef.h>' "$patch" >/dev/null
grep -F '#include "nv_stdarg.h"' "$patch" >/dev/null
grep -F '#include "nv_stddef.h"' "$patch" >/dev/null
# Active patch additions/context must not introduce direct userspace stdarg/stddef
# includes except inside the guarded compatibility wrappers themselves.
if sed 's/#HAS_UVM#//g' "$repo/debian/module/debian/patches/series.in" |
    sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' |
    while IFS= read -r active_patch; do
        awk -v patch="$active_patch" '
            /^diff .* b\/common\/inc\/nv_std(arg|def)\.h$/ { wrapper=1; next }
            /^diff / { wrapper=0 }
            /^\+/ && wrapper == 0 && /#include[[:space:]]*<(stdarg|stddef)\.h>/ {
                print patch ":" $0
            }
        ' "$repo/debian/module/debian/patches/$active_patch"
    done | grep . >/tmp/kernel-standard-headers-direct.$$; then
    cat /tmp/kernel-standard-headers-direct.$$ >&2
    rm -f /tmp/kernel-standard-headers-direct.$$
    exit 1
fi
rm -f /tmp/kernel-standard-headers-direct.$$
# Verify the wrappers expose the required symbols in normal shared-header mode.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
awk '/^diff .* b\/common\/inc\/nv_stdarg\.h$/ {emit=1; next} /^diff / {emit=0} emit && /^\+[^+]/ {sub(/^\+/, ""); print}' "$patch" > "$tmp/nv_stdarg.h"
awk '/^diff .* b\/common\/inc\/nv_stddef\.h$/ {emit=1; next} /^diff / {emit=0} emit && /^\+[^+]/ {sub(/^\+/, ""); print}' "$patch" > "$tmp/nv_stddef.h"
cat > "$tmp/check.c" <<'CHECKEOF'
#include "nv_stdarg.h"
#include "nv_stddef.h"
struct sample { int a; int b; };
static size_t use_size_t(size_t x) { return x + offsetof(struct sample, b); }
static int use_va(int count, ...)
{
    va_list ap;
    int value;
    va_start(ap, count);
    value = va_arg(ap, int);
    va_end(ap);
    return value + (int)use_size_t((size_t)count);
}
int main(void) { return use_va(1, 2) == 0; }
CHECKEOF
${CC:-cc} -I"$tmp" -c "$tmp/check.c" -o "$tmp/check.o"
