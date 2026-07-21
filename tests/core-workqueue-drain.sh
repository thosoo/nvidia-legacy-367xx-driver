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

header=$prepared/common/inc/nv-linux.h
core=$prepared/nvidia/nv.c
osi=$prepared/nvidia/os-interface.c
gvi=$prepared/nvidia/nv-gvi.c

if rg -n 'flush_scheduled_work\(\)|NV_WORKQUEUE_COMPLETE|nv_linux_workqueue_pending|nv_linux_workqueue_complete\(' "$header" "$core" "$osi" "$gvi"; then
    echo 'old counted-drain or core flush implementation remains' >&2
    exit 1
fi

for forbidden in alloc_workqueue alloc_ordered_workqueue create_singlethread_workqueue destroy_workqueue 'flush_work(' 'cancel_work_sync('; do
    if grep -F "$forbidden" "$patch" >/dev/null; then
        echo "forbidden API in core patch: $forbidden" >&2
        exit 1
    fi
done

for required in \
    'struct nv_work_s' \
    'nv_linux_workqueue_init' \
    'nv_linux_workqueue_shutdown' \
    'nv_linux_workqueue_schedule' \
    'nv_linux_workqueue_flush' \
    'kthread_create_on_node' \
    'kthread_stop' \
    'nv_linux_workqueue_next_sequence' \
    'queued_sequence' \
    'running_sequence' \
    'nv_linux_workqueue_completed_sequence'; do
    grep -F "$required" "$header" "$core" >/dev/null
 done

python3 - "$prepared" "$audit" <<'PY'
import pathlib, re, sys
root=pathlib.Path(sys.argv[1]); audit=pathlib.Path(sys.argv[2]).read_text()
header=(root/'common/inc/nv-linux.h').read_text()
core=(root/'nvidia/nv.c').read_text()
osi=(root/'nvidia/os-interface.c').read_text()
gvi=(root/'nvidia/nv-gvi.c').read_text()
for name in ['counted drain was rejected', 'callback has returned', 'Flush-barrier semantics', 'Shutdown semantics', 'os_queue_work_item', 'nv_gvi_kern_isr', 'nvidia-modeset']:
    if name not in audit:
        raise SystemExit(f'{name} missing from audit')
if 'NV_WORKQUEUE_COMPLETE' in osi + gvi:
    raise SystemExit('callbacks still signal completion internally')
for func in ['nv_linux_workqueue_init', 'nv_linux_workqueue_shutdown']:
    if func + '();' not in core:
        raise SystemExit(f'{func} is not called from init/exit paths')
main=re.search(r'static int nv_linux_workqueue_main\([^)]*\)\s*\{(?P<body>.*?)\n\}', core, re.S).group('body')
call=main.find('work->handler(work);')
complete=main.find('nv_linux_workqueue_completed_sequence = work->running_sequence')
if call < 0 or complete < 0 or not call < complete:
    raise SystemExit('worker does not mark complete after callback invocation')
if re.search(r'spin_lock[^;]*;(?:(?!spin_unlock).)*work->handler', main, re.S):
    raise SystemExit('worker may invoke callback while holding queue lock')
sched=re.search(r'int nv_linux_workqueue_schedule\([^)]*\)\s*\{(?P<body>.*?)\n\}', core, re.S).group('body')
if 'nv_linux_workqueue_stopping' not in sched or '!work->queued' not in sched or 'list_add_tail' not in sched:
    raise SystemExit('schedule path lacks shutdown rejection, duplicate coalescing, or FIFO enqueue')
flush=re.search(r'void nv_linux_workqueue_flush\([^)]*\)\s*\{(?P<body>.*?)\n\}', core, re.S).group('body')
if 'barrier = nv_linux_workqueue_next_sequence' not in flush or 'nv_linux_workqueue_completed_sequence >= barrier' not in flush:
    raise SystemExit('flush path lacks sequence barrier semantics')
shutdown=re.search(r'void nv_linux_workqueue_shutdown\([^)]*\)\s*\{(?P<body>.*?)\n\}', core, re.S).group('body')
if 'nv_linux_workqueue_stopping = NV_TRUE' not in shutdown or 'nv_linux_workqueue_flush();' not in shutdown or 'kthread_stop(thread);' not in shutdown:
    raise SystemExit('shutdown path lacks reject/flush/stop sequence')
queue= re.search(r'NV_STATUS NV_API_CALL os_queue_work_item\([^)]*\)\s*\{(?P<body>.*?)\n\}', osi, re.S).group('body')
if 'work->task.dynamic = NV_TRUE;' not in queue or 'os_free_mem((void *)work);' not in queue or 'NV_ERR_INVALID_STATE' not in queue:
    raise SystemExit('dynamic submission does not transfer/free queue ownership on rejection')
if 'os_free_mem((void *)work);' in re.search(r'static void os_execute_work_item\([^)]*\)\s*\{(?P<body>.*?)\n\}', osi, re.S).group('body'):
    raise SystemExit('dynamic callback still frees wrapper before queue-owned completion')
PY

rg -n 'NV_WORKQUEUE_SCHEDULE\(' "$prepared/nvidia" --glob '*.c' > /tmp/core-workqueue-schedule.txt
grep -F 'nvidia/os-interface.c' /tmp/core-workqueue-schedule.txt >/dev/null
grep -F 'nvidia/nv-gvi.c' /tmp/core-workqueue-schedule.txt >/dev/null
test "$(wc -l < /tmp/core-workqueue-schedule.txt)" -eq 2

rg -n 'NV_WORKQUEUE_FLUSH\(' "$prepared/nvidia" --glob '*.c' > /tmp/core-workqueue-flush.txt
grep -F 'nvidia/os-interface.c' /tmp/core-workqueue-flush.txt >/dev/null
grep -F 'nvidia/nv.c' /tmp/core-workqueue-flush.txt >/dev/null
grep -F 'nvidia/nv-gvi.c' /tmp/core-workqueue-flush.txt >/dev/null
test "$(wc -l < /tmp/core-workqueue-flush.txt)" -eq 4

rg -n '^[[:space:]]*flush_scheduled_work\(\);' "$prepared/nvidia-modeset" >/tmp/modeset-flush.txt
test "$(wc -l < /tmp/modeset-flush.txt)" -eq 4

if git -C "$repo" status --short | grep -E '\.(rej|ko|ko\.zst|deb|dsc|changes|buildinfo)$|NVIDIA-Linux-.*\.run|\.so$'; then
    echo 'generated or proprietary artifact is staged or present in repository status' >&2
    exit 1
fi
