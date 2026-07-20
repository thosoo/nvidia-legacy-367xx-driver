# `linux/ioctl32.h` reference audit for NVIDIA 367.134

| baseline | version | implementation | applicable hunks | rejected hunks | decision |
| --- | --- | --- | --- | --- | --- |
| pristine NVIDIA 367.134 | 367.134 | `nv-linux.h` includes `linux/ioctl32.h` under `NVCPU_X86_64 && !HAVE_COMPAT_IOCTL`; conftest and call sites already use `NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL` | exact failing include and already-correct consumers | obsolete `HAVE_COMPAT_IOCTL` include guard | align include guard with existing feature-detected consumers |
| NVIDIA 390xx | 390.138 | same stale `!HAVE_COMPAT_IOCTL` include guard; modern callback and manual call sites use `NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL` | negative pre-fix baseline | stale include guard | not retained |
| NVIDIA 390xx | 390.141, 390.143, 390.157 | include guard changed to `!NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL`; callbacks and manual registration use the same semantic condition | core 367 source layout matches | none | retained as nearest maintained NVIDIA legacy behavior |
| Debian 340xx | 340.108-27, patch `0017-backport-linux-ioctl32.h-changes-from-450.51.patch` | deletes `linux/syscalls.h` and `linux/ioctl32.h` includes from 340xx core and UVM headers | confirms no modern-kernel replacement header is needed | wholesale deletion would break 367 old-kernel fallback | retained only as evidence for omitting on modern kernels |
| ELRepo 367xx | `nvidia-367xx-buildfix-el8_10.patch`, `nvidia-367xx-backport-390xx-uvm.patch` | no changes to `linux/ioctl32.h`, `compat_ioctl`, `register_ioctl32_conversion`, or `NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL` | exact-tree negative baseline | no solution to import | no ELRepo-derived implementation |
| NVIDIA 450.51 | 450.51 | modern source has unconditional `.compat_ioctl` callbacks and no `linux/ioctl32.h` manual-registration include in common `nv-linux.h` | semantic origin: modern kernels use callbacks instead of manual registration | unconditional 450 layout is too new for 367 old-kernel fallback | use only semantic intent |
| final Debian 367xx | this patch | include `linux/syscalls.h` and `linux/ioctl32.h` only when `NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL` is absent | one 367-relevant hunk in `common/inc/nv-linux.h` | no RHEL/downstream conditions; no fake headers | selected |

## Final rationale

Linux 5.9+ removed the exported `linux/ioctl32.h` path used for manual 32-bit
ioctl registration. NVIDIA 367.134 already has a conftest producer and all
registration/callback consumers keyed to `NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL`.
The failing include was the only remaining stale `HAVE_COMPAT_IOCTL` consumer.
Using the same feature-detected macro for the header, init path, and teardown
path preserves 32-bit compat ioctl support without double registration.
