# Current compiler API audit

This inventory tracks the compiler families exposed after the stdarg/stddef,
`asm/kmap_types.h`, and `linux/ioctl32.h` fixes.  It intentionally treats
ELRepo as a comparison baseline only: where ELRepo did not change a 367.134 API,
the entry is recorded as a negative baseline rather than cited as provenance.

| family | baseline | driver/kernel version | patch or source path | affected API | exact implementation | differences from NVIDIA 367.134 | retained parts | rejected parts | final 367-specific design |
|---|---|---|---|---|---|---|---|---|---|
| A. vmalloc signature | pristine NVIDIA | 367.134 | `common/inc/nv-linux.h` | `__vmalloc` | calls `__vmalloc(size, GFP_KERNEL, PAGE_KERNEL)` | none | allocation accounting | unconditional pgprot argument | conftest-gated two/three argument wrapper |
| A. vmalloc signature | Debian 390xx | legacy 390xx / Linux 5.8+ | Linux 5.8 compatibility patch | `__vmalloc` | conftest/conditional two-argument call | adds feature probe | allocation accounting | version-only assumptions | `NV_VMALLOC_HAS_PGPROT_T_ARG` compile-call probe |
| A. vmalloc signature | Debian 340xx | legacy 340xx | `0018-backport-nv_vmalloc-changes-from-450.57.patch` | `__vmalloc` | backports NVIDIA 450.57 wrapper | modernizes call signature | old branch | unrelated 340 structure | same semantic wrapper in 367 header |
| A. vmalloc signature | ELRepo | exact 367.134 port | ELRepo 367 kmod patch set | `__vmalloc` | no API-specific delta identified | negative baseline | none | RHEL-specific assumptions | no ELRepo-derived code |
| A. vmalloc signature | origin | NVIDIA 450.57 / Linux pgprot removal | later NVIDIA `nv_vmalloc` | `__vmalloc` | feature-gated pgprot argument | removes hard-coded old prototype | NVIDIA accounting | unrelated driver changes | compile-time feature detection only |
| B. ioremap_nocache | pristine NVIDIA | 367.134 | `common/inc/nv-linux.h` | `ioremap_nocache` | `NV_IOREMAP_NOCACHE` calls removed helper | none | allocation labels | fake declaration/cast | alias to `NV_IOREMAP` when absent |
| B. ioremap_nocache | Debian 390xx | legacy 390xx | Linux 5.x compatibility | ioremap wrappers | maps nocache to regular `ioremap` on modern x86 | adds fallback | cache/WC helpers | local replacement function | conftest-gated macro fallback |
| B. ioremap_nocache | Debian 340xx | legacy 340xx | `0011-backport-nv_ioremap_nocache-changes-from-440.64.patch` | ioremap wrappers | backports NVIDIA 440.64 behavior | removes dependency on deleted symbol | labels and unmap | fake symbol | same macro-only behavior |
| B. ioremap_nocache | ELRepo | exact 367.134 port | ELRepo 367 kmod patch set | `ioremap_nocache` | no API-specific delta identified | negative baseline | none | RHEL macros | no ELRepo-derived code |
| B. ioremap_nocache | origin | NVIDIA 440.64 | later NVIDIA ioremap wrapper | ioremap wrappers | `ioremap` provides intended uncached mapping | modern x86 semantics | label string | local declaration | `NV_IOREMAP_NOCACHE` -> `NV_IOREMAP` when absent |
| C. SMP broadcast return type | pristine NVIDIA | 367.134 | `common/inc/nv-linux.h` | `on_each_cpu`, `smp_call_function` | returns helper return value | none | wait argument and exact call | assuming int return | conftest-gated deterministic zero for void helpers |
| C. SMP broadcast return type | Debian 390xx | legacy 390xx | Linux 5.3 compatibility | SMP helpers | wraps void return helpers | adds deterministic zero | call semantics | ignored legacy errors | same for both wrappers |
| C. SMP broadcast return type | Debian 340xx | legacy 340xx | `0008-on-each-cpu-5.3.patch` | `on_each_cpu` | returns zero after void helper | modernizes API | broadcast semantics | partial sibling omission | extend to sibling helper |
| C. SMP broadcast return type | ELRepo | exact 367.134 port | ELRepo 367 kmod patch set | SMP helpers | no API-specific delta identified | negative baseline | none | RHEL conditionals | no ELRepo-derived code |
| C. SMP broadcast return type | origin | Linux 5.3 | kernel SMP API | return types | `on_each_cpu` became void | API contract changed | execution semantics | old error path on modern kernels | probe return type with compile tests |
| D. SWIOTLB detection | pristine NVIDIA | 367.134 | `common/inc/nv-linux.h` | `swiotlb` global | compares `swiotlb == 1` | none | conservative fallback possible | private global access | exported-helper gated active check |
| D. SWIOTLB detection | Debian 390xx | legacy 390xx | SWIOTLB symbol conftests | SWIOTLB state | probes exported symbols/helpers | avoids globals | runtime decision point | unexported symbols | use exported `is_swiotlb_active` only when available |
| D. SWIOTLB detection | Debian 340xx | legacy 340xx | SWIOTLB backports | SWIOTLB state | guarded detection | avoids build failure | no private globals | declaring `extern int swiotlb` | conservative false fallback |
| D. SWIOTLB detection | ELRepo | exact 367.134 port | ELRepo 367 kmod patch set | SWIOTLB state | no safe API-specific delta identified | negative baseline | none | RHEL-only DMA ops checks | no ELRepo-derived code |
| D. SWIOTLB detection | origin | later NVIDIA/Linux SWIOTLB helpers | later NVIDIA DMA wrappers | SWIOTLB state | uses public/exported helpers or avoids decision | semantic scope narrowed | safety | CONFIG-only inference | `is_swiotlb_active()` when declared/exported, else false |
| E. SG allocation conftests | pristine NVIDIA | 367.134 | `conftest.sh` | `sg_alloc_table*` | old conftest misses modern declarations | false negative | consumer allocator choices | hand-built lists | exact prototype compile probes |
| E. SG allocation conftests | Debian 390xx | legacy 390xx | conftest compile tests | SG allocation | includes `linux/scatterlist.h` | more complete probes | macro names | force-defines | adapt exact calls |
| E. SG allocation conftests | Debian 340xx | legacy 340xx | sg_table conftests | SG allocation | probes `sg_alloc_table` | establishes pattern | compile probing | private copies | exact 367 consumer path |
| E. SG allocation conftests | ELRepo | exact 367.134 port | ELRepo 367 kmod patch set | SG allocation | no reliable API-specific delta identified | negative baseline | none | RHEL-only assumptions | no ELRepo-derived code |
| E. SG allocation conftests | origin | later NVIDIA conftest maintenance | `conftest.sh` | SG allocation | compiles actual calls | fixes false negative | macro contract | version checks | generate `NV_SG_ALLOC_TABLE*` from prototypes |
| F. ACPI hierarchy/API | pristine NVIDIA | 367.134 | `nvidia/nv-acpi.c` | ACPI device hierarchy | directly reads `children` and `node`; calls `acpi_bus_get_device` | none | driver_data ownership | private struct fields | public child iterator and handle-to-device helper |
| F. ACPI hierarchy/API | Debian 390xx | legacy 390xx | ACPI compatibility patches | ACPI hierarchy | handle or helper traversal in final branch | removes private list usage | method init/uninit shape | GPL-only helper calls and stale direct traversal | export-safe handle traversal plus legacy field probe |
| F. ACPI hierarchy/API | Debian 340xx | legacy 340xx | ACPI backports | ACPI hierarchy | compatible wrappers | resolves member removals | teardown symmetry | member recreation | same public-helper approach |
| F. ACPI hierarchy/API | ELRepo | exact 367.134 port | ELRepo 367 kmod patch set | ACPI hierarchy | no safe API-specific delta identified | negative baseline | none | RHEL assumptions | no ELRepo-derived code |
| F. ACPI hierarchy/API | origin | NVIDIA 470+ / Linux ACPI removals | later NVIDIA ACPI | ACPI hierarchy | `acpi_walk_namespace` handle traversal or later helper style | handle-scoped traversal | DDC traversal | GPL-only helper dependencies and direct list access | field-probed legacy path, otherwise handle traversal |
| G. DMA mask API | pristine NVIDIA | 367.134 | `nvidia/nv.c` | DMA mask | `pci_set_dma_mask(pdev, mask)` | none | return-code handling | discarded failures | streaming mask helper fallback |
| G. DMA mask API | Debian 390xx | legacy 390xx | pci/dma compatibility | DMA mask | `dma_set_mask(&pdev->dev, mask)` | modern API | return propagation | coherent mask assumption | streaming-only replacement |
| G. DMA mask API | Debian 340xx | legacy 340xx | pci/dma backports | DMA mask | same device DMA helper pattern | modern API | error path | silent fallback | preserve return |
| G. DMA mask API | ELRepo | exact 367.134 port | ELRepo 367 kmod patch set | DMA mask | no API-specific delta identified | negative baseline | none | RHEL macros | no ELRepo-derived code |
| G. DMA mask API | origin | NVIDIA 470.129.06 | later NVIDIA pci/dma source | DMA mask | device DMA API | kernel-compatible | streaming scope | coherent mask change without evidence | `NV_PCI_SET_DMA_MASK` wrapper |
| H. warning normalization | pristine NVIDIA | 367.134 | build/source macros | module instances | may be undefined | warning under `-Wundef` | disabled-by-default behavior | global warning suppression | default macro to 0 |

See the TSV companion for the same families in machine-readable form.
