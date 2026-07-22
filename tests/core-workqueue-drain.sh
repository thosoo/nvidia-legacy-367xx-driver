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

python3 - "$series" <<'PY'
import pathlib, sys
lines=[l.strip() for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip() and not l.lstrip().startswith('#')]
wq=lines.index('backport-core-system-workqueue-drain.patch')
uvm=lines.index('backport-uvm-core-api-compat.patch')
assert wq > uvm, 'workqueue patch must follow active compatibility sequence'
PY

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
    patch -d "$prepared" -p1 --no-backup-if-mismatch -i "$patchdir/$p" >/dev/null
done < "$series_file"
rm -f "$series_file"

if find "$prepared" \( -name '*.rej' -o -name '*.orig' -o -name '*.ko' -o -name '*.ko.zst' -o -name '*.deb' -o -name '*.dsc' -o -name '*.changes' -o -name '*.buildinfo' \) | grep .; then
    echo 'generated artifact or patch leftover found in prepared tree' >&2
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

python3 - "$prepared" "$audit" <<'PY'
import pathlib, re, sys
root=pathlib.Path(sys.argv[1]); audit=pathlib.Path(sys.argv[2]).read_text()
header=(root/'common/inc/nv-linux.h').read_text(); core=(root/'nvidia/nv.c').read_text()
osi=(root/'nvidia/os-interface.c').read_text(); gvi=(root/'nvidia/nv-gvi.c').read_text()
for text in ['typedef struct nv_task_s nv_task_t', 'nv_task_t task;', 'container_of((tq), nv_work_t, task)', 'handler_data', 'owned_allocation']:
    if text not in header:
        raise SystemExit(f'missing work-object layout text: {text}')
if re.search(r'#define NV_WORKQUEUE_INIT\([^)]*\bhandler\b[^)]*\)', header):
    raise SystemExit('NV_WORKQUEUE_INIT still uses colliding handler parameter')
for required in ['nv_linux_workqueue_has_work', 'nv_linux_workqueue_barrier_done', 'nv_linux_workqueue_worker_wait', 'nv_linux_workqueue_flush_wait', 'kthread_create_on_node', 'kthread_stop']:
    if required not in core:
        raise SystemExit(f'{required} missing')
main=re.search(r'static int nv_linux_workqueue_main\([^)]*\)\s*\{(?P<body>.*?)\n\}', core, re.S).group('body')
call2=main.find('task->handler(task);')
call3=main.find('task->handler(task->handler_data);')
cleanup=main.find('os_free_mem(owned_allocation);')
complete=main.find('nv_linux_workqueue_completed_sequence = complete_sequence')
wake=main.find('wake_up_all(&nv_linux_workqueue_flush_wait);')
if min(call2, call3, cleanup, complete, wake) < 0 or not (call2 < cleanup < complete < wake and call3 < cleanup < complete < wake):
    raise SystemExit('callback, cleanup, completion, wake ordering is wrong')
if re.search(r'os_free_mem\(owned_allocation\);(?:(?!complete_sequence).)*task->', main, re.S):
    raise SystemExit('task may be dereferenced after freeing owned allocation')
if 'work->task.owned_allocation = (void *)work;' not in osi or 'NV_ERR_INVALID_STATE' not in osi:
    raise SystemExit('dynamic ownership/reject path missing')
if 'os_free_mem((void *)work);' in re.search(r'static void os_execute_work_item\([^)]*\)\s*\{(?P<body>.*?)\n\}', osi, re.S).group('body'):
    raise SystemExit('dynamic callback still frees wrapper')
flush=re.search(r'void nv_linux_workqueue_flush\([^)]*\)\s*\{(?P<body>.*?)\n\}', core, re.S).group('body')
if 'current == nv_linux_workqueue_thread' not in flush or 'nv_linux_workqueue_barrier_done(barrier)' not in flush:
    raise SystemExit('flush lacks worker diagnostic or synchronized barrier predicate')
for name in ['counted drain was rejected', 'Work object and callback ABI', 'Flush-barrier and wait-predicate semantics', 'Single-thread serialization and scope', 'nvidia-modeset']:
    if name not in audit:
        raise SystemExit(f'{name} missing from audit')
PY

compile_probe() {
    mode=$1
    cat > "$work/probe-$mode.c" <<'CHEAD'
#include <stddef.h>
#define NV_FALSE 0
typedef unsigned long long NvU64;
typedef int NvBool;
struct list_head { struct list_head *next, *prev; };
#define INIT_LIST_HEAD(ptr) do { (ptr)->next = (ptr); (ptr)->prev = (ptr); } while (0)
#define container_of(ptr, type, member) ((type *)((char *)(ptr) - offsetof(type, member)))
CHEAD
    sed -n '/typedef struct nv_task_s nv_task_t;/,/^#define NV_MAX_REGISTRY_KEYS_LENGTH/p' "$header" | sed '$d' >> "$work/probe-$mode.c"
    if [ "$mode" = 2 ]; then
        cat >> "$work/probe-$mode.c" <<'C2'
static void os_execute_work_item(nv_task_t *task) { (void)task; }
int main(void) { nv_work_t storage; nv_work_t *work = &storage; NV_WORKQUEUE_INIT(&work->task, os_execute_work_item, (void *)work); return NV_WORKQUEUE_UNPACK_DATA(&work->task) != work; }
C2
    else
        cat >> "$work/probe-$mode.c" <<'C3'
static int called;
static void os_execute_work_item(void *data) { called = (data != 0); }
int main(void) { nv_work_t storage; nv_work_t *work = &storage; NV_WORKQUEUE_INIT(&work->task, os_execute_work_item, (void *)work); work->task.handler(work->task.handler_data); return called ? 0 : 1; }
C3
    fi
    cc -DNV_INIT_WORK_ARGUMENT_COUNT="$mode" -Wall -Werror "$work/probe-$mode.c" -o "$work/probe-$mode"
    "$work/probe-$mode"
}
work=$(mktemp -d)
trap "rm -rf '$work'; $cleanup" EXIT
compile_probe 2
compile_probe 3

rg -n 'NV_WORKQUEUE_SCHEDULE\(' "$prepared/nvidia" --glob '*.c' > "$work/core-workqueue-schedule.txt"
grep -F 'nvidia/os-interface.c' "$work/core-workqueue-schedule.txt" >/dev/null
grep -F 'nvidia/nv-gvi.c' "$work/core-workqueue-schedule.txt" >/dev/null
test "$(wc -l < "$work/core-workqueue-schedule.txt")" -eq 2

rg -n 'NV_WORKQUEUE_FLUSH\(' "$prepared/nvidia" --glob '*.c' > "$work/core-workqueue-flush.txt"
grep -F 'nvidia/os-interface.c' "$work/core-workqueue-flush.txt" >/dev/null
grep -F 'nvidia/nv.c' "$work/core-workqueue-flush.txt" >/dev/null
grep -F 'nvidia/nv-gvi.c' "$work/core-workqueue-flush.txt" >/dev/null
test "$(wc -l < "$work/core-workqueue-flush.txt")" -eq 4

rg -n '^[[:space:]]*flush_scheduled_work\(\);' "$prepared/nvidia-modeset" >"$work/modeset-flush.txt"
test "$(wc -l < "$work/modeset-flush.txt")" -eq 2

if git -C "$repo" status --short | grep -E '\.(rej|ko|ko\.zst|deb|dsc|changes|buildinfo)$|NVIDIA-Linux-.*\.run|\.so$'; then
    echo 'generated or proprietary artifact is staged or present in repository status' >&2
    exit 1
fi
