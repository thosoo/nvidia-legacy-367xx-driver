#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patch=$repo/debian/module/debian/patches/fix-sg-allocation-conftests.patch
test -f "$patch"
grep -F '#include <linux/scatterlist.h>' "$patch" >/dev/null
grep -F 'sg_alloc_table(table, nents, gfp)' "$patch" >/dev/null
grep -F 'sg_alloc_table_from_pages(table, pages, n_pages,' "$patch" >/dev/null
grep -F 'NV_SG_ALLOC_TABLE_FROM_PAGES_PRESENT' "$patch" >/dev/null
grep -F 'append_conftest "types"' "$patch" >/dev/null
! grep -F 'compile_check_conftest "$CODE" "NV_SG_ALLOC_TABLE_PRESENT" "" "functions"' "$patch" >/dev/null
! grep -F 'compile_check_conftest "$CODE" "NV_SG_ALLOC_TABLE_FROM_PAGES_PRESENT" "" "functions"' "$patch" >/dev/null

# The regression must not fabricate checked-in conftest evidence.
for artifact in \
    "$repo/sg-conftest-source.c" \
    "$repo/sg-conftest-command.txt" \
    "$repo/sg-conftest-stderr.txt" \
    "$repo/sg-conftest-result.txt"
do
    if [ -e "$artifact" ]; then
        echo "fabricated SG conftest artifact remains in repository: $artifact" >&2
        exit 1
    fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/sg-conftest-source.c" <<'CEOF'
typedef unsigned int gfp_t;
struct sg_table { int dummy; };
struct page;
int sg_alloc_table(struct sg_table *table, unsigned int nents, gfp_t gfp)
{
    return table != 0 && nents != 0 ? (int)gfp : -1;
}
int sg_alloc_table_from_pages(struct sg_table *table,
                              struct page **pages,
                              unsigned int n_pages,
                              unsigned int offset,
                              unsigned long size,
                              gfp_t gfp)
{
    return table != 0 && pages != 0 && n_pages != 0 && size != 0 ? (int)(offset + gfp) : -1;
}
int test(struct sg_table *table,
         struct page **pages,
         unsigned int n_pages,
         unsigned int offset,
         unsigned long size,
         gfp_t gfp)
{
    return sg_alloc_table(table, n_pages, gfp) +
           sg_alloc_table_from_pages(table, pages, n_pages, offset, size, gfp);
}
CEOF
cmd="${CC:-cc} -Wall -Werror -c $tmp/sg-conftest-source.c -o $tmp/sg-conftest-source.o"
printf '%s\n' "$cmd" > "$tmp/sg-conftest-command.txt"
set +e
sh -c "$cmd" > "$tmp/sg-conftest-stdout.txt" 2> "$tmp/sg-conftest-stderr.txt"
status=$?
set -e
printf '%s\n' "$status" > "$tmp/sg-conftest-result.txt"
test "$status" -eq 0
test -s "$tmp/sg-conftest-command.txt"
test -s "$tmp/sg-conftest-result.txt"
test -f "$tmp/sg-conftest-source.o"
