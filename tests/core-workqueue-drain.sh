#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
patchdir=$repo/debian/module/debian/patches
patch=$patchdir/backport-core-system-workqueue-drain.patch
audit=$patchdir/workqueue-drain-api-audit.md
series=$patchdir/series.in

grep -Fx 'backport-core-system-workqueue-drain.patch' "$series" >/dev/null
test -f "$patch"
test -f "$audit"

prepared=${1:-}
cleanup=:
if [ -z "$prepared" ]; then
    tmp=$(mktemp -d)
    cleanup="rm -rf '$tmp'"
    prepared=$(tools/prepare-kernel-tree.sh bookworm "$tmp")
fi
trap "$cleanup" EXIT

series_file=$(mktemp)
sed 's/#HAS_UVM#//g' "$series" | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' > "$series_file"
while IFS= read -r p; do
    patch -d "$prepared" -p1 -i "$patchdir/$p" >/dev/null
done < "$series_file"
rm -f "$series_file"

if find "$prepared" -name '*.rej' -o -name '*.ko' -o -name '*.ko.zst' -o -name '*.deb' -o -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' | grep .; then
    echo 'generated artifact found in prepared tree' >&2
    exit 1
fi

if rg -n '#define NV_WORKQUEUE_FLUSH\(\).*flush_scheduled_work|flush_scheduled_work\(\)' "$prepared/common/inc/nv-linux.h"; then
    echo 'core NV_WORKQUEUE_FLUSH still uses flush_scheduled_work' >&2
    exit 1
fi

for forbidden in alloc_workqueue alloc_ordered_workqueue create_singlethread_workqueue destroy_workqueue 'flush_work(' 'cancel_work_sync('; do
    if grep -F "$forbidden" "$patch" >/dev/null; then
        echo "forbidden API in core patch: $forbidden" >&2
        exit 1
    fi
done

rg -n 'NV_WORKQUEUE_SCHEDULE\(' "$prepared/nvidia" --glob '*.c' > /tmp/core-workqueue-schedule.txt
grep -F 'nvidia/os-interface.c' /tmp/core-workqueue-schedule.txt >/dev/null
grep -F 'nvidia/nv-gvi.c' /tmp/core-workqueue-schedule.txt >/dev/null
test "$(wc -l < /tmp/core-workqueue-schedule.txt)" -eq 2

rg -n 'NV_WORKQUEUE_FLUSH\(' "$prepared/nvidia" --glob '*.c' > /tmp/core-workqueue-flush.txt
grep -F 'nvidia/os-interface.c' /tmp/core-workqueue-flush.txt >/dev/null
grep -F 'nvidia/nv.c' /tmp/core-workqueue-flush.txt >/dev/null
grep -F 'nvidia/nv-gvi.c' /tmp/core-workqueue-flush.txt >/dev/null
test "$(wc -l < /tmp/core-workqueue-flush.txt)" -eq 4

python3 - "$prepared" "$audit" <<'PY'
import pathlib, re, sys
root=pathlib.Path(sys.argv[1]); audit=pathlib.Path(sys.argv[2]).read_text()
osi=(root/'nvidia/os-interface.c').read_text()
gvi=(root/'nvidia/nv-gvi.c').read_text()
for name in ['os_queue_work_item', 'nv_gvi_kern_isr', 'os_execute_work_item', 'nv_gvi_kern_bh', 'os_flush_work_queue', 'nv_stop_device', 'nv_gvi_kern_suspend']:
    if name not in audit:
        raise SystemExit(f'{name} missing from audit')
body=re.search(r'static void os_execute_work_item\([^)]*\)\s*\{(?P<body>.*?)\n\}', osi, re.S).group('body')
if body.count('NV_WORKQUEUE_COMPLETE();') != 2:
    raise SystemExit('os_execute_work_item completion paths not structurally accounted')
if not re.search(r'if \(nv_kmem_cache_alloc_stack\(&sp\) != 0\).*?NV_WORKQUEUE_COMPLETE\(\);.*?return;', body, re.S):
    raise SystemExit('stack allocation failure path lacks completion before return')
gbody=re.search(r'void nv_gvi_kern_bh\([^)]*\)\s*\{(?P<body>.*?)\n\}', gvi, re.S).group('body')
if gbody.count('NV_WORKQUEUE_COMPLETE();') != 1:
    raise SystemExit('nv_gvi_kern_bh completion not structurally accounted')
PY

rg -n '^[[:space:]]*flush_scheduled_work\(\);' "$prepared/nvidia-modeset" >/tmp/modeset-flush.txt
test "$(wc -l < /tmp/modeset-flush.txt)" -eq 4
grep -F 'nvidia-modeset' "$audit" >/dev/null

if git -C "$repo" status --short | grep -E '\.(rej|ko|ko\.zst|deb|dsc|changes|buildinfo)$|NVIDIA-Linux-.*\.run|\.so$'; then
    echo 'generated or proprietary artifact is staged or present in repository status' >&2
    exit 1
fi
