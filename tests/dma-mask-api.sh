#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch=$repo/debian/module/debian/patches/backport-dma-mask-api.patch
test -f "$patch"
grep -F 'NV_PCI_SET_DMA_MASK_PRESENT' "$patch" >/dev/null
grep -F 'dma_set_mask(&pdev->dev, mask)' "$patch" >/dev/null
grep -F 'return pci_set_dma_mask(pdev, mask);' "$patch" >/dev/null
if awk '/^\+[^+]/ && /(^|[^A-Za-z0-9_])pci_set_dma_mask\(/ && !/conftest_pci_set_dma_mask/ && !/return pci_set_dma_mask\(pdev, mask\);/ { bad=1 } END { exit bad }' "$patch"; then
    :
else
    echo 'raw added pci_set_dma_mask call escaped the wrapper' >&2
    exit 1
fi
