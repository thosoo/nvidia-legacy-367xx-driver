# SWIOTLB reference audit

`nv_dma_maps_swiotlb()` is a runtime query used to decide whether the current
PCI device is being bounced through SWIOTLB.  NVIDIA 367.134 read the private
kernel global `swiotlb == 1`, which is no longer a public module ABI on Linux
6.1/6.12.  The compatibility patch therefore rejects `extern int swiotlb`,
`CONFIG_SWIOTLB`-only inference, and private DMA-ops inspection.

Comparison summary: pristine 367.134 uses the private global; Debian 390xx and
340xx packaging evolved toward exported-symbol/public-helper probes; ELRepo's
exact 367.134 port is a negative baseline for this API; later NVIDIA/Linux code
uses public helpers or avoids private globals.  The selected 367-specific design
uses `is_swiotlb_active(&pdev->dev)` only when the compile probe proves it is
declared for modules.  If not available, the function returns false rather than
claiming device bounce buffering from `CONFIG_SWIOTLB=y` alone.

Runtime semantics: `is_swiotlb_active()` is device-scoped and therefore closer
to the old intent than a configuration test.  Fallback false is conservative:
it may skip SWIOTLB-specific NVIDIA behavior on kernels without an exported
public query, but it avoids unexported symbols and unsafe private global access.
