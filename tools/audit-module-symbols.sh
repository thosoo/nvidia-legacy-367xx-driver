#!/bin/sh
set -eu
if [ "$#" -ne 4 ]; then
    echo "usage: $0 MODULE_DIRECTORY TARGET_KERNEL_MODULE_SYMVERS BUILT_MODULE_MODULE_SYMVERS OUTPUT_DIRECTORY" >&2
    exit 2
fi
module_dir=$(readlink -f "$1")
kernel_symvers=$(readlink -f "$2")
sibling_symvers=$(readlink -f "$3")
out=$(readlink -m "$4")
mkdir -p "$out"
for f in "$kernel_symvers" "$sibling_symvers"; do
    if [ ! -s "$f" ]; then
        echo "Module.symvers not found or empty: $f" >&2
        exit 1
    fi
done
kernel_header_dir=$(dirname "$kernel_symvers")
case "$kernel_header_dir" in
    /lib/modules/*/build) kernel=${kernel_header_dir#/lib/modules/}; kernel=${kernel%/build} ;;
    /usr/src/linux-headers-*) kernel=${kernel_header_dir#/usr/src/linux-headers-} ;;
    *) kernel=unknown ;;
esac
${NM:-nm} --version | sed -n '1p' > "$out/nm-version.txt"
printf '%s\n' "$kernel" > "$out/kernel-release.txt"
printf '%s\n' "$kernel_header_dir" > "$out/kernel-header-directory.txt"
printf '%s\n' "$kernel_symvers" > "$out/kernel-module-symvers-path.txt"
printf '%s\n' "$sibling_symvers" > "$out/sibling-module-symvers-path.txt"
sha256sum "$kernel_symvers" > "$out/kernel-module-symvers.sha256"
sha256sum "$sibling_symvers" > "$out/sibling-module-symvers.sha256"
: > "$out/missing-symbols.txt"
: > "$out/gpl-only-symbols.txt"
: > "$out/duplicate-symbols.txt"
: > "$out/conflicting-duplicates.txt"
workqueue_symbols='kthread_create_on_node kthread_stop wake_up_process __wake_up schedule wait_woken prepare_to_wait_event finish_wait cond_resched'
lookup_symbol()
{
    table=$1
    source=$2
    symbol=$3
    awk -v s="$symbol" -v source="$source" '
        $2 == s { print source, $3, $4, $1; found=1 }
        END { exit found ? 0 : 1 }
    ' "$table"
}
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
                printf '%s %s weak-undefined-not-required - - -\n' "$sym" "$type" >> "$out/$mod.symbol-audit.txt"
                continue
                ;;
        esac
        krec=$(lookup_symbol "$kernel_symvers" kernel "$sym" || true)
        srec=$(lookup_symbol "$sibling_symvers" sibling-module "$sym" || true)
        if [ -n "$krec" ] && [ -n "$srec" ]; then
            printf '%s\n' "$mod $sym $krec | $srec" >> "$out/duplicate-symbols.txt"
            kpayload=$(printf '%s\n' "$krec" | awk '{print $2, $3, $4}' | sort -u)
            spayload=$(printf '%s\n' "$srec" | awk '{print $2, $3, $4}' | sort -u)
            if [ "$kpayload" != "$spayload" ]; then
                printf '%s\n' "$mod $sym $krec | $srec" >> "$out/conflicting-duplicates.txt"
                continue
            fi
        fi
        rec=${krec:-$srec}
        if [ -z "$rec" ]; then
            printf '%s %s\n' "$mod" "$sym" >> "$out/missing-symbols.txt"
            printf '%s %s missing - - -\n' "$sym" "$type" >> "$out/$mod.symbol-audit.txt"
            continue
        fi
        provider_source=$(printf '%s\n' "$rec" | awk 'NR == 1 {print $1}')
        provider_module=$(printf '%s\n' "$rec" | awk 'NR == 1 {print $2}')
        export_class=$(printf '%s\n' "$rec" | awk 'NR == 1 {print $3}')
        crc=$(printf '%s\n' "$rec" | awk 'NR == 1 {print $4}')
        printf '%s %s %s %s %s %s\n' "$sym" "$type" "$provider_source" "$provider_module" "$export_class" "$crc" >> "$out/$mod.symbol-audit.txt"
        if [ "$export_class" = EXPORT_SYMBOL_GPL ]; then
            printf '%s %s %s %s\n' "$mod" "$sym" "$provider_source" "$export_class" >> "$out/gpl-only-symbols.txt"
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
if [ -s "$out/conflicting-duplicates.txt" ]; then
    echo "conflicting duplicate symbols found" >&2
    cat "$out/conflicting-duplicates.txt" >&2
    exit 1
fi
printf '%s\n' pass > "$out/result.txt"
