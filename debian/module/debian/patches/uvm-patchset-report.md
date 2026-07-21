# UVM patchset construction report

## backport-uvm-mmap-lock-api.patch

| field | value |
|---|---|
| exact predecessor | `backport-timekeeping-scheduler-mmap-lock-api.patch` |
| exact successor | `backport-uvm-core-api-compat.patch` |
| files touched | `conftest.sh`, `nvidia-uvm/nvidia-uvm.Kbuild`, `nvidia-uvm/uvm8.c`, `nvidia-uvm/uvm8_lock.h`, `nvidia-uvm/uvm8_mem.c`, `nvidia-uvm/uvm8_migrate.c`, `nvidia-uvm/uvm8_policy.c`, `nvidia-uvm/uvm8_tools.c`, `nvidia-uvm/uvm8_va_block.c`, `nvidia-uvm/uvm8_va_range.h`, `nvidia-uvm/uvm8_va_space.c` |
| files existed before patch | yes |
| quilt top before refresh | `patches/backport-uvm-mmap-lock-api.patch` |
| quilt top after refresh | `patches/backport-uvm-mmap-lock-api.patch` |
| target pop/push result | `quilt pop`; `quilt push --fuzz=0` succeeded |
| complete pop-all/push-all result | `quilt pop -a`; `quilt push -a` succeeded |
| focused integrity result | `tests/module-patch-integrity.sh PREPARED_TREE` succeeded |
| full-series integrity result | `tests/module-patch-integrity.sh --full-series PREPARED_TREE` succeeded |
| fuzz count in target patch | 0 |
| offset count in target patch | 0 |
| reject count in target patch | 0 |
| unexpected `.orig` / `.rej` count | 0 |

## backport-uvm-core-api-compat.patch

| field | value |
|---|---|
| exact predecessor | `backport-uvm-mmap-lock-api.patch` |
| exact successor | `conftest-verbose.patch` |
| files touched | `common/inc/nv.h`, `conftest.sh`, `nvidia-uvm/nvidia-uvm.Kbuild`, `nvidia-uvm/uvm8.c`, `nvidia-uvm/uvm8_tools.c`, `nvidia-uvm/uvm8_va_range.h`, `nvidia-uvm/uvm_linux.h` |
| files existed before patch | yes |
| quilt top before refresh | `patches/backport-uvm-core-api-compat.patch` |
| quilt top after refresh | `patches/backport-uvm-core-api-compat.patch` |
| target pop/push result | `quilt pop`; `quilt push --fuzz=0` succeeded |
| complete pop-all/push-all result | `quilt pop -a`; `quilt push -a` succeeded |
| focused integrity result | `tests/module-patch-integrity.sh PREPARED_TREE` succeeded |
| full-series integrity result | `tests/module-patch-integrity.sh --full-series PREPARED_TREE` succeeded |
| fuzz count in target patch | 0 |
| offset count in target patch | 0 |
| reject count in target patch | 0 |
| unexpected `.orig` / `.rej` count | 0 |

Notes:

- Both patches were created and refreshed in a prepared 367.134 source tree with Quilt at their real active-series positions.
- Patch headers use Quilt `-p ab` output (`--- a/path`, `+++ b/path`) with no `diff -Naur` banner and no temporary build-tree paths.
- The full-series Quilt run still records inherited fuzz/offsets in older historical patches, but the two UVM patches apply cleanly with `--fuzz=0` at their exact positions.

## dependency-barrier strict probe refresh

- Refreshed only `backport-uvm-core-api-compat.patch` through Quilt at its exact series position after `backport-uvm-mmap-lock-api.patch`.
- The refreshed probe removes stale-object false positives by deleting `conftest$$.o`, compiling with strict implicit-declaration, incompatible-pointer, and return-type diagnostics, and defining `NV_SMP_READ_BARRIER_DEPENDS_PRESENT` only when the compiler exits `0` and creates a new object.
- The expected Bookworm/Trixie selected implementation is `implicit dependency ordering` with `#undef NV_SMP_READ_BARRIER_DEPENDS_PRESENT`.

## mmap consumer refresh after run 89

- Changed patch: `backport-uvm-mmap-lock-api.patch`.
- Exact predecessor: `backport-timekeeping-scheduler-mmap-lock-api.patch`.
- Exact successor: `backport-uvm-core-api-compat.patch`.
- Added target-patch file: `nvidia-uvm/uvm8_va_range.c`.
- Source edits: `uvm_down_read_mmap_sem(&current->mm->mmap_sem)` -> `uvm_down_read_mmap_sem(current->mm)` and `uvm_up_read_mmap_sem(&current->mm->mmap_sem)` -> `uvm_up_read_mmap_sem(current->mm)` in `uvm8_test_va_range_info`.
- Downstream active patches inspected after the target patch: `backport-uvm-core-api-compat.patch`, `conftest-verbose.patch`, `use-kbuild-module-directory.patch`, `use-kbuild-compiler.patch`, `use-kbuild-flags.patch`, `nvidia-use-ARCH.o_binary.patch`, and `nvidia-modeset-use-ARCH.o_binary.patch`.
- Downstream overlap result: only `backport-uvm-core-api-compat.patch` touches UVM files after the mmap patch, and it did not reintroduce an obsolete mmap-semaphore argument; no downstream patch required refresh.
- Final cumulative source audit result: `uvm8_test_va_range_info` contains `uvm_down_read_mmap_sem(current->mm)` and `uvm_up_read_mmap_sem(current->mm)`, with zero production UVM wrapper calls passing `&...->mmap_sem` to migrated wrappers.
- Validation: target patch applied, reversed, and reapplied with `patch -p1 --fuzz=0`; Quilt target pop/push and complete `quilt pop -a`/`quilt push -a` completed; focused and full module patch-integrity tests were rerun against Bookworm and Trixie prepared trees.
