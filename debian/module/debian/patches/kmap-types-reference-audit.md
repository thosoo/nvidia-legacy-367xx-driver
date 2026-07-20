# `asm/kmap_types.h` reference audit for NVIDIA 367.134

## Consumer audit

The pristine NVIDIA 367.134 kernel tree has one direct include of
`asm/kmap_types.h`, in `common/inc/nv-linux.h`. Searches for `km_type`,
`enum km_type`, `KM_BOUNCE_READ`, `KM_SKB_SUNRPC_DATA`, `KM_USER0`, `KM_USER1`,
`KM_TYPE_NR`, `kmap_atomic`, and `kunmap_atomic` found no direct 367.134
consumers outside that include. The include is therefore a stale compatibility
include for page-table lookup history, not a provider of actively used symbols
on the Bookworm/Trixie build path.

## Baseline comparison

| baseline | version | implementation | applicable to 367 | decision |
| --- | --- | --- | --- | --- |
| NVIDIA 390xx | 390.141 | `common/inc/nv-linux.h` still unconditionally includes `asm/kmap_types.h` | shows the failing pre-fix state | rejected as too old for Linux 5.11+ |
| NVIDIA 390xx | 390.143 | `common/inc/nv-linux.h` no longer includes `asm/kmap_types.h` | confirms NVIDIA removed the dependency for Linux 5.11 | retain semantic result |
| NVIDIA 390xx | 390.157 | include remains absent; changelog records the Linux 5.11 `asm/kmap_types.h` failure fix | nearest maintained legacy behavior | retain semantic result |
| Debian 340xx | 340.108-27, patch `0028-backport-asm-kmap_types.h-changes-from-460.32.03.patch` | deletes the include from `nv-linux.h` and UVM's `nvidia_uvm_linux.h` | older-source-layout precedent; 367.134 has only the common `nv-linux.h` occurrence | retain only the 367-relevant common-header hunk |
| ELRepo 367xx | `nvidia-367xx-buildfix-el8_10.patch` | guards the include with `LINUX_VERSION_CODE < KERNEL_VERSION(5, 11, 0) && (RHEL_MAJOR != 8)` | exact-tree placement in 367.134 | retain the Linux-version guard, reject RHEL-specific macro |
| later NVIDIA origin | 460.32.03 | `common/inc/nv-linux.h` does not include `asm/kmap_types.h` | modern API intent: no replacement header is required | use as provenance for omitting on Linux 5.11+ |
| final Debian 367xx | this patch | include `asm/kmap_types.h` only when `LINUX_VERSION_CODE < KERNEL_VERSION(5, 11, 0)` | preserves old-kernel compatibility while fixing Bookworm/Trixie | selected |

## Target selection

* First affected kernel: Linux 5.11, where the exported `asm/kmap_types.h`
  header disappeared.
* Below Linux 5.11: keep the include for older kernels where the header may
  still exist.
* Bookworm Linux 6.1: include omitted.
* Trixie Linux 6.12: include omitted.
* Replacement header: none; no consumed `km_type`/`KM_*`/`kmap_atomic` symbol
  requires replacement in NVIDIA 367.134.
* RHEL-specific code imported: no.
* Fake header or symlink created: no.
