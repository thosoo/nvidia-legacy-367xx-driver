#!/bin/sh
set -eu
if [ "$#" -ne 3 ]; then
    echo "usage: $0 MODULE_DIRECTORY MODULE_SYMVERS_OR_HEADER_DIRECTORY OUTPUT_DIRECTORY" >&2
    exit 2
fi
module_dir=$(readlink -f "$1")
input=$(readlink -f "$2")
out=$(readlink -m "$3")
if [ -d "$input" ]; then
    header_dir=$input
    symvers=$header_dir/Module.symvers
else
    symvers=$input
    header_dir=$(dirname "$symvers")
fi
mkdir -p "$out"
if [ ! -s "$symvers" ]; then
    echo "target Module.symvers not found or empty: $symvers" >&2
    exit 1
fi
case "$header_dir" in
    /lib/modules/*/build) kernel=${header_dir#/lib/modules/}; kernel=${kernel%/build} ;;
    /usr/src/linux-headers-*) kernel=${header_dir#/usr/src/linux-headers-} ;;
    *) kernel=unknown ;;
esac
${NM:-nm} --version | sed -n '1p' > "$out/nm-version.txt"
printf '%s\n' "$kernel" > "$out/kernel-release.txt"
printf '%s\n' "$header_dir" > "$out/header-directory.txt"
printf '%s\n' "$symvers" > "$out/module-symvers-path.txt"
sha256sum "$symvers" > "$out/module-symvers.sha256"
: > "$out/missing-symbols.txt"
: > "$out/gpl-only-symbols.txt"
workqueue_symbols='kthread_create_on_node kthread_stop wake_up_process __wake_up schedule wait_woken prepare_to_wait_event finish_wait cond_resched'
for mod in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
    ko=$module_dir/$mod.ko
    test -s "$ko" || { echo "missing module: $ko" >&2; exit 1; }
    ${NM:-nm} -u --format=posix "$ko" | awk 'NF >= 2 { print $1, $2 }' | sort -u > "$out/$mod.undefined.txt"
    : > "$out/$mod.symbol-audit.txt"
    : > "$out/$mod.workqueue-symbols.txt"
    while read -r sym type; do
        [ -n "${sym:-}" ] || continue
        case "$type" in
            w|W|v|V)
                printf '%s %s weak-undefined-not-required\n' "$sym" "$type" >> "$out/$mod.symbol-audit.txt"
                continue
                ;;
        esac
        line=$(awk -v s="$sym" '$2 == s {print; found=1; exit} END { if (!found) exit 1 }' "$symvers" || true)
        if [ -z "$line" ]; then
            printf '%s %s\n' "$mod" "$sym" >> "$out/missing-symbols.txt"
            printf '%s %s missing\n' "$sym" "$type" >> "$out/$mod.symbol-audit.txt"
            continue
        fi
        class=$(printf '%s\n' "$line" | awk '{print $4}')
        printf '%s %s %s\n' "$sym" "$type" "$class" >> "$out/$mod.symbol-audit.txt"
        if [ "$class" = EXPORT_SYMBOL_GPL ]; then
            printf '%s %s %s\n' "$mod" "$sym" "$class" >> "$out/gpl-only-symbols.txt"
        fi
    done < "$out/$mod.undefined.txt"
    for sym in $workqueue_symbols; do
        if awk -v symbol="$sym" '$1 == symbol { found=1 } END { exit found ? 0 : 1 }' "$out/$mod.undefined.txt"; then
            awk -v symbol="$sym" '$1 == symbol { print; found=1 } END { exit found ? 0 : 1 }' "$out/$mod.symbol-audit.txt" >> "$out/$mod.workqueue-symbols.txt" || {
                echo "$mod: workqueue symbol $sym missing from detailed audit" >&2
                exit 1
            }
        fi
    done
done
if [ -s "$out/missing-symbols.txt" ]; then
    echo "missing symbols found" >&2
    cat "$out/missing-symbols.txt" >&2
    exit 1
fi
if [ -s "$out/gpl-only-symbols.txt" ]; then
    echo "GPL-only symbols referenced" >&2
    cat "$out/gpl-only-symbols.txt" >&2
    exit 1
fi
printf '%s\n' pass > "$out/result.txt"
