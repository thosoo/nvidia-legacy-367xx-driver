#!/bin/sh
set -eu
if [ "$#" -ne 3 ]; then
    echo "usage: $0 MODULE_DIRECTORY KERNEL_RELEASE OUTPUT_DIRECTORY" >&2
    exit 2
fi
module_dir=$(readlink -f "$1")
kernel=$2
out=$(readlink -m "$3")
symvers=/lib/modules/$kernel/build/Module.symvers
mkdir -p "$out"
if [ ! -s "$symvers" ]; then
    echo "target Module.symvers not found: $symvers" >&2
    exit 1
fi
printf '%s\n' "$kernel" > "$out/kernel-release.txt"
printf '%s\n' "$symvers" > "$out/module-symvers-path.txt"
: > "$out/missing-symbols.txt"
: > "$out/gpl-only-symbols.txt"
workqueue_symbols='kthread_create_on_node kthread_stop wake_up_process __wake_up schedule wait_woken prepare_to_wait_event finish_wait'
for mod in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
    ko=$module_dir/$mod.ko
    test -s "$ko" || { echo "missing module: $ko" >&2; exit 1; }
    nm -u "$ko" | awk '{print $NF}' | sed '/^$/d' | sort -u > "$out/$mod.undefined.txt"
    : > "$out/$mod.symbol-audit.txt"
    while IFS= read -r sym; do
        [ -n "$sym" ] || continue
        line=$(awk -v s="$sym" '$2 == s {print; found=1; exit} END { if (!found) exit 1 }' "$symvers" || true)
        if [ -z "$line" ]; then
            printf '%s %s\n' "$mod" "$sym" >> "$out/missing-symbols.txt"
            printf '%s missing\n' "$sym" >> "$out/$mod.symbol-audit.txt"
            continue
        fi
        class=$(printf '%s\n' "$line" | awk '{print $4}')
        printf '%s %s\n' "$sym" "$class" >> "$out/$mod.symbol-audit.txt"
        if [ "$class" = EXPORT_SYMBOL_GPL ]; then
            printf '%s %s %s\n' "$mod" "$sym" "$class" >> "$out/gpl-only-symbols.txt"
        fi
    done < "$out/$mod.undefined.txt"
    for sym in $workqueue_symbols; do
        if grep -Fx "$sym" "$out/$mod.undefined.txt" >/dev/null; then
            grep -F "^$sym " "$out/$mod.symbol-audit.txt" >> "$out/$mod.workqueue-symbols.txt" || true
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
