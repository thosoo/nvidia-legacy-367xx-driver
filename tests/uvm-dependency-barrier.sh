#!/bin/sh
set -eu
patch=debian/module/debian/patches/backport-uvm-core-api-compat.patch
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc=${CC:-cc}
flags='-Wall -Werror -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type'
cat > "$work/modern.c" <<'C'
static inline void uvm_read_dependency_barrier(void) { }
static long atomic_long_read(long *p) { return *p; }
void *load_block(long *slot) { void *block = (void *)atomic_long_read(slot); uvm_read_dependency_barrier(); return block; }
C
$cc $flags -c "$work/modern.c" -o "$work/modern.o"
cat > "$work/legacy.c" <<'C'
#define NV_SMP_READ_BARRIER_DEPENDS_PRESENT
static int called;
static inline void smp_read_barrier_depends(void) { called = 1; }
static inline void uvm_read_dependency_barrier(void) { smp_read_barrier_depends(); }
int main(void) { uvm_read_dependency_barrier(); return called ? 0 : 1; }
C
$cc $flags -c "$work/legacy.c" -o "$work/legacy.o"
grep -F 'uvm_read_dependency_barrier();' "$patch" >/dev/null
grep -F 'NV_SMP_READ_BARRIER_DEPENDS_PRESENT' "$patch" >/dev/null
raw_calls=$(grep -E '^\+.*smp_read_barrier_depends\(\);' "$patch" | wc -l)
test "$raw_calls" -le 2
