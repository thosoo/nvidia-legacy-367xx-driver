#!/bin/sh
set -eu
patch=debian/module/debian/patches/backport-timekeeping-scheduler-mmap-lock-api.patch
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc=${CC:-cc}; flags='-Wall -Werror -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type'
cat > "$work/modern.c" <<'C'
#define NV_MMAP_READ_LOCK_PRESENT
struct mm_struct { int opaque; }; static void mmap_read_lock(struct mm_struct *mm) { (void)mm; } static void mmap_read_unlock(struct mm_struct *mm) { (void)mm; }
static inline void nv_mmap_read_lock(struct mm_struct *mm) { mmap_read_lock(mm); }
static inline void nv_mmap_read_unlock(struct mm_struct *mm) { mmap_read_unlock(mm); }
int main(void) { struct mm_struct mm; nv_mmap_read_lock(&mm); nv_mmap_read_unlock(&mm); return 0; }
C
$cc $flags -c "$work/modern.c" -o "$work/modern.o"
cat > "$work/legacy.c" <<'C'
#define NV_MM_HAS_MMAP_SEM
struct rw_semaphore { int lock; }; struct mm_struct { struct rw_semaphore mmap_sem; }; static void down_read(struct rw_semaphore *s) { (void)s; } static void up_read(struct rw_semaphore *s) { (void)s; }
static inline void nv_mmap_read_lock(struct mm_struct *mm) { down_read(&mm->mmap_sem); }
static inline void nv_mmap_read_unlock(struct mm_struct *mm) { up_read(&mm->mmap_sem); }
int main(void) { struct mm_struct mm; nv_mmap_read_lock(&mm); nv_mmap_read_unlock(&mm); return 0; }
C
$cc $flags -c "$work/legacy.c" -o "$work/legacy.o"
cat > "$work/negative.c" <<'C'
struct mm_struct { int opaque; }; int main(void) { struct mm_struct mm; (void)mm.mmap_sem; return 0; }
C
if $cc $flags -c "$work/negative.c" -o "$work/negative.o" 2>"$work/negative.err"; then exit 1; fi
grep -F 'nv_mmap_read_lock(mm);' "$patch" >/dev/null
! grep -F '+    down_read(&mm->mmap_sem);' "$patch" >/dev/null || true
