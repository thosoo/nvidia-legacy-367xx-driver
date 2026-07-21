#!/bin/sh
set -eu
patch=debian/module/debian/patches/backport-uvm-core-api-compat.patch
grep -F '#include "nvstatus.h"' "$patch" >/dev/null
grep -F '#include "nv-misc.h"' "$patch" >/dev/null
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc=${CC:-cc}; flags='-Wall -Werror -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type'
cat > "$work/nvtypes.h" <<'H'
typedef int NvS32; typedef unsigned int NvU32;
H
cat > "$work/nvstatus.h" <<'H'
typedef unsigned int NV_STATUS;
H
cat > "$work/nv-misc.h" <<'H'
#ifndef BOOL
#define BOOL NvS32
#endif
H
cat > "$work/nvCpuUuid.h" <<'H'
H
cat > "$work/nv_stdarg.h" <<'H'
H
cat > "$work/nv.h" <<'H'
#include <nvtypes.h>
#include "nvstatus.h"
#include "nv-misc.h"
typedef NV_STATUS (*nvPmaEvictRangeCallback)(void *, unsigned long long, unsigned long long);
static inline BOOL nv_header_order_bool(void) { return 1; }
H
cat > "$work/test.c" <<'C'
#include "nv.h"
static NV_STATUS cb(void *p, unsigned long long a, unsigned long long b) { (void)p; return (NV_STATUS)(a + b); }
int main(void) { nvPmaEvictRangeCallback f = cb; return nv_header_order_bool() ? (int)f(0, 0, 0) : 1; }
C
$cc $flags -I "$work" -c "$work/test.c" -o "$work/test.o"
