#include <linux/scatterlist.h>
int test(struct sg_table *table, struct page **pages, unsigned int n_pages, unsigned int offset, unsigned long size, gfp_t gfp) { return sg_alloc_table_from_pages(table, pages, n_pages, offset, size, gfp); }
