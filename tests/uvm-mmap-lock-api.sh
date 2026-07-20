#!/bin/sh
set -eu
patch=debian/module/debian/patches/backport-uvm-mmap-lock-api.patch
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cc=${CC:-cc}
flags='-Wall -Werror -Werror=implicit-function-declaration -Werror=incompatible-pointer-types -Werror=return-type'
cat > "$work/modern.c" <<'C'
#define NV_MMAP_ASSERT_LOCKED_PRESENT
#define NV_MMAP_ASSERT_WRITE_LOCKED_PRESENT
struct mm_struct { int id; };
static int locked, write_locked, read_locked, read_unlocked;
#define UVM_ASSERT(x) do { (void)sizeof(x); } while (0)
typedef enum { UVM_LOCK_MODE_ANY, UVM_LOCK_MODE_SHARED, UVM_LOCK_MODE_EXCLUSIVE } uvm_lock_mode_t;
static void mmap_assert_locked(struct mm_struct *mm) { locked += mm->id; }
static void mmap_assert_write_locked(struct mm_struct *mm) { write_locked += mm->id; }
static void nv_mmap_read_lock(struct mm_struct *mm) { read_locked += mm->id; }
static void nv_mmap_read_unlock(struct mm_struct *mm) { read_unlocked += mm->id; }
static int uvm_check_locked_mmap_sem(struct mm_struct *mm, uvm_lock_mode_t mode) { return mm && mode <= UVM_LOCK_MODE_EXCLUSIVE; }
#define uvm_record_lock_mmap_sem_read(mm) do { (void)(mm); } while (0)
#define uvm_record_unlock_mmap_sem_read(mm) do { (void)(mm); } while (0)
#define uvm_record_unlock_mmap_sem_read_out_of_order(mm) do { (void)(mm); } while (0)
static inline void uvm_mmap_assert_locked(struct mm_struct *mm) { mmap_assert_locked(mm); }
static inline void uvm_mmap_assert_write_locked(struct mm_struct *mm) { mmap_assert_write_locked(mm); }
#define uvm_assert_mmap_sem_locked_mode(mm, mode) ({ struct mm_struct *_mm = (mm); if ((mode) == UVM_LOCK_MODE_EXCLUSIVE) uvm_mmap_assert_write_locked(_mm); else uvm_mmap_assert_locked(_mm); UVM_ASSERT(uvm_check_locked_mmap_sem(_mm, (mode))); })
#define uvm_down_read_mmap_sem(mm) ({ struct mm_struct *_mm = (mm); uvm_record_lock_mmap_sem_read(_mm); nv_mmap_read_lock(_mm); })
#define uvm_up_read_mmap_sem(mm) ({ struct mm_struct *_mm = (mm); nv_mmap_read_unlock(_mm); uvm_record_unlock_mmap_sem_read(_mm); })
int main(void) { struct mm_struct mm = { 3 }; uvm_assert_mmap_sem_locked_mode(&mm, UVM_LOCK_MODE_EXCLUSIVE); uvm_down_read_mmap_sem(&mm); uvm_up_read_mmap_sem(&mm); return !(write_locked == 3 && read_locked == 3 && read_unlocked == 3); }
C
$cc $flags -c "$work/modern.c" -o "$work/modern.o"
cat > "$work/legacy.c" <<'C'
#define NV_MM_HAS_MMAP_SEM
struct rw_semaphore { int locked; }; struct mm_struct { struct rw_semaphore mmap_sem; };
#define UVM_ASSERT(x) do { (void)sizeof(x); } while (0)
static int rwsem_is_locked(struct rw_semaphore *sem) { return sem->locked; }
static void down_read(struct rw_semaphore *sem) { sem->locked = 1; }
static void up_read(struct rw_semaphore *sem) { sem->locked = 0; }
static inline void nv_mmap_read_lock(struct mm_struct *mm) { down_read(&mm->mmap_sem); }
static inline void nv_mmap_read_unlock(struct mm_struct *mm) { up_read(&mm->mmap_sem); }
static inline void uvm_mmap_assert_locked(struct mm_struct *mm) { UVM_ASSERT(rwsem_is_locked(&mm->mmap_sem)); }
int main(void) { struct mm_struct mm = { { 0 } }; nv_mmap_read_lock(&mm); uvm_mmap_assert_locked(&mm); nv_mmap_read_unlock(&mm); return 0; }
C
$cc $flags -c "$work/legacy.c" -o "$work/legacy.o"
cat > "$work/negative.c" <<'C'
struct mm_struct { int dummy; };
int main(void) { struct mm_struct mm; return mm.mmap_sem; }
C
if $cc $flags -c "$work/negative.c" -o "$work/negative.o" 2>"$work/negative.err"; then exit 1; fi
grep -F 'struct mm_struct *_mm = (mm)' "$patch" >/dev/null
grep -F 'uvm_record_lock_raw((mm)' "$patch" >/dev/null
if grep -E '^\+.*&[^;]*mmap_sem' "$patch" | grep -v 'NV_MM_HAS_MMAP_SEM' | grep -v 'mm_has_mmap_sem' | grep -v 'rwsem_is_locked' >/dev/null; then
    echo 'new UVM mmap patch adds an unguarded mmap_sem address' >&2
    exit 1
fi
