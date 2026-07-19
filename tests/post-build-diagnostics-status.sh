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
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/binary-build.log" <<'LOGEOF'
gcc-12 -Wp,-MMD,/work/binary-source/kernel-source-tree/nvidia/.nv-frontend.o.d -nostdinc -c -o /work/binary-source/kernel-source-tree/nvidia/nv-frontend.o /work/binary-source/kernel-source-tree/nvidia/nv-frontend.c
LOGEOF
if grep -Eq '(^|[[:space:]])CC[[:space:]]+\[M\]' "$tmp/binary-build.log" || \
   { grep -Eq 'kernel-source-tree/.*/(nvidia|nvidia-modeset|nvidia-drm|nvidia-uvm)/[^[:space:]]+\.c' "$tmp/binary-build.log" && \
     grep -Eq '[[:space:]]-c[[:space:]]' "$tmp/binary-build.log" && \
     grep -Eq '[[:space:]]-o[[:space:]][^[:space:]]*kernel-source-tree/(nvidia|nvidia-modeset|nvidia-drm|nvidia-uvm)/[^[:space:]]+\.o' "$tmp/binary-build.log"; }; then
    :
else
    echo "module compiler detection misses explicit gcc module compile commands" >&2
    exit 1
fi
