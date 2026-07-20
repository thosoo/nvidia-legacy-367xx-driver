#!/bin/sh
set -eu
patch=debian/module/debian/patches/backport-uvm-core-api-compat.patch
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc=${CC:-cc}
flags='-Wall -Werror -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type'

make_probe_runner()
{
    dir=$1
    mkdir -p "$dir/include/asm"
    {
        printf '%s\n' '#!/bin/sh' 'set -eu' "CC=${cc}" "CFLAGS=\"-I $dir/include\"" 'CONFTEST_PREAMBLE=' 'out=$PWD/conftest-output.h' ': > "$out"' 'append_conftest() { cat >> "$out"; }'
        sed -n '/^+dependency_barrier_compile_check_conftest()/,/^+}$/p' "$patch" | sed 's/^+//'
        cat <<'SH'
CODE="
#include <asm/barrier.h>
void conftest_smp_read_barrier_depends(void)
{
    smp_read_barrier_depends();
}"
dependency_barrier_compile_check_conftest "$CODE" "NV_SMP_READ_BARRIER_DEPENDS_PRESENT" "" "types"
SH
    } > "$dir/probe.sh"
    chmod +x "$dir/probe.sh"
}

# Modern absent-helper case: the header exists, but the helper is undeclared.
modern=$work/modern
mkdir -p "$modern/include/asm"
: > "$modern/include/asm/barrier.h"
make_probe_runner "$modern"
(
    cd "$modern"
    sh ./probe.sh
)
grep -F '#undef NV_SMP_READ_BARRIER_DEPENDS_PRESENT' "$modern/conftest-output.h" >/dev/null
grep -F '#undef NV_SMP_READ_BARRIER_DEPENDS_PRESENT' "$modern/conftest-dependency-barrier-diagnostics/nv_smp_read_barrier_depends_present.definition.txt" >/dev/null
grep -F 'implicit dependency ordering' "$modern/conftest-dependency-barrier-diagnostics/selected-implementation.txt" >/dev/null
test "$(cat "$modern/conftest-dependency-barrier-diagnostics/nv_smp_read_barrier_depends_present.object-created.txt")" = no
if [ "$(cat "$modern/conftest-dependency-barrier-diagnostics/nv_smp_read_barrier_depends_present.exit.txt")" -eq 0 ]; then
    echo 'absent-helper strict probe unexpectedly succeeded' >&2
    exit 1
fi

# Legacy helper-present case: the exact same production helper and source generation define the feature.
legacy=$work/legacy
mkdir -p "$legacy/include/asm"
cat > "$legacy/include/asm/barrier.h" <<'H'
static inline void smp_read_barrier_depends(void) { }
H
make_probe_runner "$legacy"
(
    cd "$legacy"
    sh ./probe.sh
)
grep -F '#define NV_SMP_READ_BARRIER_DEPENDS_PRESENT' "$legacy/conftest-output.h" >/dev/null
grep -F '#define NV_SMP_READ_BARRIER_DEPENDS_PRESENT' "$legacy/conftest-dependency-barrier-diagnostics/nv_smp_read_barrier_depends_present.definition.txt" >/dev/null
grep -F 'smp_read_barrier_depends' "$legacy/conftest-dependency-barrier-diagnostics/selected-implementation.txt" >/dev/null
test "$(cat "$legacy/conftest-dependency-barrier-diagnostics/nv_smp_read_barrier_depends_present.object-created.txt")" = yes
test "$(cat "$legacy/conftest-dependency-barrier-diagnostics/nv_smp_read_barrier_depends_present.exit.txt")" -eq 0

# Production-consumer shape: modern branch compiles with the macro undefined and no helper declaration.
cat > "$work/consumer-modern.c" <<'C'
static inline void uvm_read_dependency_barrier(void)
{
#if defined(NV_SMP_READ_BARRIER_DEPENDS_PRESENT)
    smp_read_barrier_depends();
#else
#endif
}
static long atomic_long_read(long *p) { return *p; }
void *load_block(long *slot) { void *block = (void *)atomic_long_read(slot); uvm_read_dependency_barrier(); return block; }
C
$cc $flags -c "$work/consumer-modern.c" -o "$work/consumer-modern.o"

cat > "$work/consumer-legacy.c" <<'C'
#define NV_SMP_READ_BARRIER_DEPENDS_PRESENT
static int called;
static inline void smp_read_barrier_depends(void) { called = 1; }
static inline void uvm_read_dependency_barrier(void)
{
#if defined(NV_SMP_READ_BARRIER_DEPENDS_PRESENT)
    smp_read_barrier_depends();
#else
#endif
}
int main(void) { uvm_read_dependency_barrier(); return called ? 0 : 1; }
C
$cc $flags -c "$work/consumer-legacy.c" -o "$work/consumer-legacy.o"

grep -F 'dependency_barrier_compile_check_conftest' "$patch" >/dev/null
grep -F -- '-Werror=implicit-function-declaration' "$patch" >/dev/null
grep -F 'rm -f "$OBJ"' "$patch" >/dev/null
if grep -F '+#define NV_SMP_READ_BARRIER_DEPENDS_PRESENT' "$patch" >/dev/null; then
    echo 'feature macro must not be forced in the patch' >&2
    exit 1
fi
raw_calls=$(grep -E '^\+.*smp_read_barrier_depends\(\);' "$patch" | wc -l)
test "$raw_calls" -le 2
