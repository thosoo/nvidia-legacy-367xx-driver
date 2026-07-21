#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch=$repo/debian/module/debian/patches/backport-dma-mask-api.patch
test -f "$patch"
grep -F 'NV_PCI_SET_DMA_MASK_PRESENT' "$patch" >/dev/null
grep -F 'dma_set_mask(&pdev->dev, mask)' "$patch" >/dev/null
grep -F 'nv_dma_map_page' "$patch" >/dev/null
grep -F 'nv_dma_unmap_page' "$patch" >/dev/null
grep -F 'nv_dma_map_sg' "$patch" >/dev/null
grep -F 'nv_dma_unmap_sg' "$patch" >/dev/null
grep -F 'nv_dma_mapping_error' "$patch" >/dev/null
grep -F -- '-Werror=implicit-function-declaration' "$patch" >/dev/null
test -f "$repo/debian/module/debian/patches/pci-dma-api-audit.tsv"
if awk '/^\+[^+]/ && /(^|[^A-Za-z0-9_])pci_set_dma_mask\(/ && !/conftest_pci_set_dma_mask/ && !/return pci_set_dma_mask\(pdev, mask\);/ { bad=1 } END { exit bad }' "$patch"; then
    :
else
    echo 'raw added pci_set_dma_mask call escaped the wrapper' >&2
    exit 1
fi
python3 - "$patch" <<'PY'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
for i, line in enumerate(lines):
    if not line.startswith('+') or line.startswith('+++'):
        continue
    if not any(token in line for token in ('pci_map_page(', 'pci_unmap_page(', 'pci_map_sg(', 'pci_unmap_sg(', 'pci_dma_mapping_error(', 'PCI_DMA_BIDIRECTIONAL')):
        continue
    window = '\n'.join(lines[max(0, i-20):i+1])
    if 'conftest_' in window or 'NV_PCI_DMA_MAPPING_API_PRESENT' in window or 'The old probe called pci_dma_mapping_error' in line:
        continue
    raise SystemExit(f'legacy PCI DMA alias is not confined to conftest or legacy wrapper branch: {line}')
PY

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/dma-compat.c" <<'CEOF'
typedef unsigned long size_t;
typedef unsigned long dma_addr_t;
struct device { int dummy; };
struct pci_dev { struct device dev; unsigned long *dma_mask; };
struct page { int dummy; };
struct scatterlist { int dummy; };
#define DMA_BIDIRECTIONAL 0
#if LEGACY_DMA
#define PCI_DMA_BIDIRECTIONAL 0
static dma_addr_t pci_map_page(struct pci_dev *pdev, struct page *page, unsigned long offset, size_t size, int dir)
{ (void)pdev; (void)page; (void)offset; (void)size; (void)dir; return 1; }
static void pci_unmap_page(struct pci_dev *pdev, dma_addr_t addr, size_t size, int dir)
{ (void)pdev; (void)addr; (void)size; (void)dir; }
static int pci_map_sg(struct pci_dev *pdev, struct scatterlist *sgl, int nents, int dir)
{ (void)pdev; (void)sgl; (void)dir; return nents; }
static void pci_unmap_sg(struct pci_dev *pdev, struct scatterlist *sgl, int nents, int dir)
{ (void)pdev; (void)sgl; (void)nents; (void)dir; }
static int pci_dma_mapping_error(struct pci_dev *pdev, dma_addr_t addr)
{ (void)pdev; return addr == 0; }
#define NV_PCI_DMA_MAPPING_API_PRESENT 1
#else
static dma_addr_t dma_map_page(struct device *dev, struct page *page, unsigned long offset, size_t size, int dir)
{ (void)dev; (void)page; (void)offset; (void)size; (void)dir; return 1; }
static void dma_unmap_page(struct device *dev, dma_addr_t addr, size_t size, int dir)
{ (void)dev; (void)addr; (void)size; (void)dir; }
static int dma_map_sg(struct device *dev, struct scatterlist *sgl, int nents, int dir)
{ (void)dev; (void)sgl; (void)dir; return nents; }
static void dma_unmap_sg(struct device *dev, struct scatterlist *sgl, int nents, int dir)
{ (void)dev; (void)sgl; (void)nents; (void)dir; }
static int dma_mapping_error(struct device *dev, dma_addr_t addr)
{ (void)dev; return addr == 0; }
#endif
#if defined(NV_PCI_DMA_MAPPING_API_PRESENT)
#define NV_DMA_BIDIRECTIONAL PCI_DMA_BIDIRECTIONAL
#else
#define NV_DMA_BIDIRECTIONAL DMA_BIDIRECTIONAL
#endif
static inline dma_addr_t nv_dma_map_page(struct pci_dev *pdev, struct page *page, unsigned long offset, size_t size)
{
#if defined(NV_PCI_DMA_MAPPING_API_PRESENT)
    return pci_map_page(pdev, page, offset, size, NV_DMA_BIDIRECTIONAL);
#else
    return dma_map_page(&pdev->dev, page, offset, size, NV_DMA_BIDIRECTIONAL);
#endif
}
static inline void nv_dma_unmap_page(struct pci_dev *pdev, dma_addr_t addr, size_t size)
{
#if defined(NV_PCI_DMA_MAPPING_API_PRESENT)
    pci_unmap_page(pdev, addr, size, NV_DMA_BIDIRECTIONAL);
#else
    dma_unmap_page(&pdev->dev, addr, size, NV_DMA_BIDIRECTIONAL);
#endif
}
static inline int nv_dma_map_sg(struct pci_dev *pdev, struct scatterlist *sgl, int nents)
{
#if defined(NV_PCI_DMA_MAPPING_API_PRESENT)
    return pci_map_sg(pdev, sgl, nents, NV_DMA_BIDIRECTIONAL);
#else
    return dma_map_sg(&pdev->dev, sgl, nents, NV_DMA_BIDIRECTIONAL);
#endif
}
static inline void nv_dma_unmap_sg(struct pci_dev *pdev, struct scatterlist *sgl, int nents)
{
#if defined(NV_PCI_DMA_MAPPING_API_PRESENT)
    pci_unmap_sg(pdev, sgl, nents, NV_DMA_BIDIRECTIONAL);
#else
    dma_unmap_sg(&pdev->dev, sgl, nents, NV_DMA_BIDIRECTIONAL);
#endif
}
static inline int nv_dma_mapping_error(struct pci_dev *pdev, dma_addr_t addr)
{
#if defined(NV_PCI_DMA_MAPPING_API_PRESENT)
    return pci_dma_mapping_error(pdev, addr);
#else
    return dma_mapping_error(&pdev->dev, addr);
#endif
}
int main(void)
{
    struct pci_dev pdev = { 0 };
    struct page page = { 0 };
    struct scatterlist sg = { 0 };
    dma_addr_t addr = nv_dma_map_page(&pdev, &page, 0, 4096);
    int n = nv_dma_map_sg(&pdev, &sg, 1);
    int err = nv_dma_mapping_error(&pdev, addr);
    nv_dma_unmap_sg(&pdev, &sg, n);
    nv_dma_unmap_page(&pdev, addr, 4096);
    return err;
}
CEOF
${CC:-cc} -Wall -Werror -Werror=implicit-function-declaration -DLEGACY_DMA=1 -c "$tmp/dma-compat.c" -o "$tmp/dma-compat-legacy.o"
${CC:-cc} -Wall -Werror -Werror=implicit-function-declaration -DLEGACY_DMA=0 -c "$tmp/dma-compat.c" -o "$tmp/dma-compat-generic.o"
cat > "$tmp/dma-false-positive.c" <<'CEOF'
typedef unsigned long dma_addr_t;
struct pci_dev;
int main(void)
{
    struct pci_dev *pdev = 0;
    return pci_dma_mapping_error(pdev, (dma_addr_t)0);
}
CEOF
if ${CC:-cc} -Wall -Werror=implicit-function-declaration -c "$tmp/dma-false-positive.c" -o "$tmp/dma-false-positive.o" 2> "$tmp/dma-false-positive.err"; then
    echo 'undeclared pci_dma_mapping_error unexpectedly compiled' >&2
    exit 1
fi
