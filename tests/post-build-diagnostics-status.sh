#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$repo/tools/build-in-debian.sh"
grep -F 'post-build-diagnostics.trace.txt' "$script" >/dev/null
grep -F 'post-build-diagnostics.exit' "$script" >/dev/null
grep -F 'post-build-diagnostics-failures.txt' "$script" >/dev/null
grep -F 'exit "$binary_status"' "$script" >/dev/null
if grep -F 'exit "$diagnostics_status"' "$script" >/dev/null; then
    echo "diagnostic status must not replace binary build status" >&2
    exit 1
fi
for diagnostic in \
    kernel-build-progress.txt \
    kernel-build-excerpt.txt \
    kernel-source-tree-created.txt \
    module-series-applied.txt \
    kernel-kbuild-invoked.txt \
    module-c-compiler-reached.txt \
    module-linker-reached.txt \
    modpost-reached.txt \
    kernel-compilation-reached.txt \
    binary-package-list.txt \
    module-kbuild-M-value.txt \
    module-quilt-series-complete.txt \
    module-quilt-failed-patch.txt
 do
    grep -F "$diagnostic" "$script" >/dev/null || {
        echo "missing diagnostic writer for $diagnostic" >&2
        exit 1
    }
 done
