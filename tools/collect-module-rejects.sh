#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then
    echo "usage: $0 BINARY_SOURCE LOG_DIRECTORY" >&2
    exit 2
fi
binary_source=$(readlink -m "$1")
log_dir=$(readlink -m "$2")
mkdir -p "$log_dir"
: > "$log_dir/module-quilt-reject-files.txt"
for reject_root in \
    "$binary_source/kernel-source-tree" \
    "$binary_source/kernel-source-tree/.pc"
do
    if test -d "$reject_root"; then
        find "$reject_root" -type f -name '*.rej' -print
    fi
done > "$log_dir/module-quilt-reject-files.txt"
sed "s#^$binary_source/##" "$log_dir/module-quilt-reject-files.txt" \
    > "$log_dir/module-quilt-reject-files-relative.txt"
: > "$log_dir/module-quilt-reject-contents.txt"
while IFS= read -r reject; do
    test -n "$reject" || continue
    {
        printf '\n===== %s =====\n' "$reject"
        cat "$reject"
    } >> "$log_dir/module-quilt-reject-contents.txt"
done < "$log_dir/module-quilt-reject-files.txt"
