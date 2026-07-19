# 0071 `nv_vma_start_write` safety audit

`0071-backport-nv_vma_start_write-changes-from-570.169.patch` is not a
mechanical context-only patch. It adds an NVIDIA-side replacement for kernel
`vma_start_write()` when that inline helper would reference GPL-only
`__vma_start_write`.

## Local 367.134 source inspection

The pristine NVIDIA 367.134 kernel tree does not contain `vma_start_write`,
`__vma_start_write`, `VMA_LOCK_OFFSET`, `vma_writer_wait`, `vm_lock_seq`, or an
existing `nv_vma_start_write` helper. Those names are introduced solely by the
inherited patch and target newer Linux VMA-lock internals.

The existing conftest framework handles export-symbol checks through the symbol
test dispatch: `is_export_symbol_present_*` produces
`NV_IS_EXPORT_SYMBOL_PRESENT_*`, while `is_export_symbol_gpl_*` produces
`NV_IS_EXPORT_SYMBOL_GPL_*`. Therefore a 367-specific port would register
`is_export_symbol_gpl___vma_start_write` in `NV_CONFTEST_SYMBOL_COMPILE_TESTS`,
not in a generic compile-test list.

## Current tested kernels

Bookworm 6.1 and Trixie 6.12 predate the Linux 6.15-era change where
`vma_start_write()` calls out to GPL-only `__vma_start_write`. The special
`!NV_CAN_CALL_VMA_START_WRITE` branch is therefore not expected to be selected
on the current Bookworm/Trixie targets, but the patch is future-facing and
should not be disabled solely for that reason.

## Safety-sensitive implementation points

The inherited implementation manipulates:

- `vma->vm_refcnt`
- `vma->vmlock_dep_map`
- `vma->vm_mm->vma_writer_wait`
- `vma->vm_lock_seq`
- `VMA_LOCK_OFFSET`
- `__is_vma_write_locked()`
- `ACCESS_PRIVATE(vma, __vm_flags)`

These affect VMA lock ownership, refcount lifetime, wait-state cleanup,
lockdep accounting, and write-side mutation of VMA flags. A wrong port can leak
references, leave lockdep state unbalanced, update `vm_lock_seq` without the
right ownership, or mutate VMA flags without the required mmap/VMA lock
preconditions.

## Stop decision

Patches 0064, 0066, and 0067 were rebased cleanly. Patch 0071 is intentionally
left unresolved until an authoritative implementation comparison verifies the
VMA locking and refcount behavior for the exact kernel family being targeted.
No force-applied VMA-locking code is committed.
