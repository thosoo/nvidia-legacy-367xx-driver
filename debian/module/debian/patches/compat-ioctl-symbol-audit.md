# Compat ioctl family audit for NVIDIA 367.134

| File | Symbol or condition | Definition/consumer | Bookworm | Trixie | Old-kernel action |
| --- | --- | --- | --- | --- | --- |
| `common/inc/nv-linux.h` | `linux/syscalls.h`, `linux/ioctl32.h` | headers for legacy manual ioctl32 registration | omitted | omitted | included only when `NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL` is absent |
| `conftest.sh` | `NV_FILE_OPERATIONS_HAS_COMPAT_IOCTL` | producer probing `struct file_operations.compat_ioctl` | defined | defined | undefined on old kernels without the callback field |
| `nvidia/nv-frontend.c` | `.compat_ioctl = nvidia_frontend_compat_ioctl` | modern 32-bit ioctl callback | compiled | compiled | omitted when callback field is absent |
| `nvidia/os-interface.c` | `register_ioctl32_conversion()` / `unregister_ioctl32_conversion()` | legacy registration and teardown | omitted | omitted | compiled as a matched pair |
| `nvidia/nv.c` | `nv_register_compat_ioctl()` / `nv_unregister_compat_ioctl()` callers | module init/exit wiring | omitted | omitted | compiled as a matched pair |
| `nvidia-uvm/uvm8.c`, `uvm8_tools.c`, `uvm_unsupported.c` | `.compat_ioctl` callbacks | UVM modern callback path | compiled | compiled | omitted when callback field is absent |

The family must have exactly one active mechanism:

| kernel/API configuration | header included | compat callback present | manual registration compiled | manual unregister compiled |
| --- | --- | --- | --- | --- |
| old kernel without `file_operations.compat_ioctl` | yes | no | yes | yes |
| Bookworm Linux 6.1 | no | yes | no | no |
| Trixie Linux 6.12 | no | yes | no | no |
