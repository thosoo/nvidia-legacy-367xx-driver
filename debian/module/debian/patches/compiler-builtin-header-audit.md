# Compiler-provided header audit for NVIDIA 367.134

The Bookworm and Trixie Kbuild commands compile the NVIDIA module sources with
`-nostdinc`. The failing include family is therefore every kernel-context use of
compiler-provided `<stdarg.h>` or `<stddef.h>`, not only the first reported
`common/inc/os-interface.h` error.

| File | Current include | Symbols consumed | Compilation context | Replacement |
| --- | --- | --- | --- | --- |
| `common/inc/nv.h` | `<stdarg.h>` | `va_list` | RM kernel/shared header | `"nv_stdarg.h"` |
| `common/inc/os-interface.h` | `<stdarg.h>` | `va_list` | OS interface kernel/shared header | `"nv_stdarg.h"` |
| `nvidia-modeset/nvidia-modeset-os-interface.h` | `<stddef.h>`, `<stdarg.h>` | `size_t`, `va_list` | modeset kernel interface header | `"nv_stddef.h"`, `"nv_stdarg.h"` |
| `nvidia-modeset/nvkms.h` | `<stddef.h>` | `size_t` | modeset shared header | `"nv_stddef.h"` |
| `nvidia-uvm/uvm8_mmu.c` | `<stdarg.h>` | variadic push helpers using `va_list` machinery through macros | UVM kernel translation unit | `"nv_stdarg.h"` |

`common/inc/nv-linux.h` already uses `<linux/stddef.h>` for `NULL` and
`offsetof`, so it is not changed.

The wrappers are intentionally small: under `__KERNEL__` they include Linux's
standard header equivalents, and outside the kernel they keep the compiler
headers for shared-header use. This follows the design precedent of later
NVIDIA `nv_stdarg.h` wrappers without importing unrelated later-driver macros
or adding a conftest dependency before the include graph is established.
