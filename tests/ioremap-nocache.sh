#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch=$repo/debian/module/debian/patches/backport-ioremap-nocache.patch
test -f "$patch"
grep -F 'NV_IOREMAP_NOCACHE_PRESENT' "$patch" >/dev/null
grep -F 'void *ptr = ioremap(phys, size);' "$patch" >/dev/null
grep -F 'VM_ALLOC_RECORD(ptr, size, "vm_ioremap_nocache")' "$patch" >/dev/null
if grep -F 'void *ioremap_nocache' "$patch" >/dev/null; then
    echo 'must not add a local ioremap_nocache declaration or replacement' >&2
    exit 1
fi
