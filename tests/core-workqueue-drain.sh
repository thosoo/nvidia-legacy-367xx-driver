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
grep -F "Description:" "$patch" >/dev/null
grep -F "Author:" "$patch" >/dev/null
grep -F "Forwarded:" "$patch" >/dev/null

python3 - "$series" <<'PY'
import pathlib, sys
lines=[l.strip() for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip() and not l.lstrip().startswith('#')]
wq=lines.index('backport-core-system-workqueue-drain.patch')
uvm=lines.index('backport-uvm-core-api-compat.patch')
assert wq > uvm, 'workqueue patch must follow active compatibility sequence'
PY

echo prepare-tree
prepared=${1:-}
cleanup=:
if [ -z "$prepared" ]; then
    tmp=$(mktemp -d)
    cleanup="rm -rf '$tmp'"
    prepared=$(tools/prepare-kernel-tree.sh bookworm "$tmp")
fi
trap "$cleanup" EXIT

echo apply-series
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

echo inspect-patched-source
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
for text in ['typedef struct nv_task_s nv_task_t', 'nv_task_t task;', 'container_of((tq), nv_work_t, task)', 'handler_data', 'owned_allocation', 'requeueable', 'NV_WORKQUEUE_FLUSH_STATUS']:
    if text not in header:
        raise SystemExit(f'missing work-object layout text: {text}')
if re.search(r'#define NV_WORKQUEUE_INIT\([^)]*\bhandler\b[^)]*\)', header):
    raise SystemExit('NV_WORKQUEUE_INIT still uses colliding handler parameter')
for required in ['NV_WQ_UNINITIALIZED', 'NV_WQ_INITIALIZING', 'NV_WQ_RUNNING', 'NV_WQ_DRAINING', 'NV_WQ_STOPPING', 'NV_WQ_STOPPED', 'nv_linux_workqueue_has_work', 'nv_linux_workqueue_barrier_done', 'nv_linux_workqueue_worker_wait', 'nv_linux_workqueue_flush_wait', 'nv_linux_workqueue_shutdown_wait', 'kthread_create_on_node', 'kthread_stop']:
    if required not in core:
        raise SystemExit(f'{required} missing')
main=re.search(r'static int nv_linux_workqueue_main\([^)]*\)\s*\{(?P<body>.*?)\n\}', core, re.S).group('body')
if 'wait_event_interruptible(nv_linux_workqueue_worker_wait' not in main:
    raise SystemExit('worker idle wait must be interruptible')
if 'wait_event(nv_linux_workqueue_worker_wait' in main:
    raise SystemExit('worker idle wait must not use plain wait_event')
if main.count('kthread_should_stop()') < 2 or 'if (wait_rc != 0)' not in main or 'cond_resched();' not in main or 'continue;' not in main:
    raise SystemExit('worker interruptible wait must recheck stop and retry interruptions')
call2=main.find('task->handler(task);')
call3=main.find('task->handler(task->handler_data);')
cleanup=main.find('os_free_mem(owned_allocation);')
complete=main.find('nv_linux_workqueue_completed_sequence = complete_sequence')
wake=main.find('wake_up_all(&nv_linux_workqueue_flush_wait);')
if min(call2, call3, cleanup, complete, wake) < 0 or not (call2 < cleanup < complete < wake and call3 < cleanup < complete < wake):
    raise SystemExit('callback, cleanup, completion, wake ordering is wrong')
if re.search(r'os_free_mem\(owned_allocation\);(?:(?!complete_sequence).)*task->', main, re.S):
    raise SystemExit('task may be dereferenced after freeing owned allocation')
if 'NV_WORKQUEUE_FLUSH_STATUS() == 0' not in osi or 'NV_ERR_ILLEGAL_ACTION' not in osi:
    raise SystemExit('os_flush_work_queue does not propagate worker flush failure')
if 'work->task.requeueable = NV_FALSE;' not in osi or 'work->task.owned_allocation = (void *)work;' not in osi or 'NV_ERR_INVALID_STATE' not in osi:
    raise SystemExit('dynamic ownership/reject path missing')
if 'os_free_mem((void *)work);' in re.search(r'static void os_execute_work_item\([^)]*\)\s*\{(?P<body>.*?)\n\}', osi, re.S).group('body'):
    raise SystemExit('dynamic callback still frees wrapper')
def order(haystack, first, second, label):
    i=haystack.find(first); j=haystack.find(second)
    if i < 0 or j < 0 or i > j:
        raise SystemExit(label)
flush_once=re.search(r'static int nv_linux_workqueue_flush_once\([^)]*\)\s*\{(?P<body>.*?)\n\}', core, re.S).group('body')
flush=re.search(r'int nv_linux_workqueue_flush\([^)]*\)\s*\{(?P<body>.*?)\n\}', core, re.S).group('body')
if 'current == nv_linux_workqueue_thread' not in flush_once or 'return -EDEADLK;' not in flush_once or 'nv_linux_workqueue_barrier_done(barrier)' not in flush_once:
    raise SystemExit('flush lacks worker diagnostic or synchronized barrier predicate')
if flush.count('nv_linux_workqueue_flush_once()') != 2:
    raise SystemExit('flush must use two FIFO barriers to include one callback-generated requeue wave')

schedule=re.search(r'int nv_linux_workqueue_schedule\([^)]*\)\s*\{(?P<body>.*?)\n\}', core, re.S).group('body')
if 'task->requeueable || (task->queued_sequence == 0)' not in schedule:
    raise SystemExit('dynamic one-shot/static requeue schedule rule missing')
for needle in ['WARN_ON_ONCE(nv_linux_workqueue_shutdown() != 0)', 'WARN_ON_ONCE(NV_WORKQUEUE_FLUSH_STATUS() != 0)', 'return status;']:
    if needle not in core + gvi:
        raise SystemExit(f'direct flush call-site handling missing {needle}')
if 'BUG_ON(nv_linux_workqueue_shutdown()' in core or 'BUG_ON(NV_WORKQUEUE_FLUSH_STATUS()' in core:
    raise SystemExit('kernel-fatal BUG_ON lifecycle assertion remains')
stop_start=core.find('static void nv_stop_device')
stop_end=core.find('static int nv_start_device', stop_start)
stop_body=core[stop_start:stop_end]
order(stop_body, 'rm_shutdown_gvi_device(sp, nv);', 'NV_WORKQUEUE_FLUSH_STATUS() != 0', 'GVI stop must quiesce producer before flush')
order(stop_body, 'NV_WORKQUEUE_FLUSH_STATUS() != 0', 'free_irq(nv->interrupt_line', 'GVI stop must flush before IRQ release')

shutdown_start=core.find('int nv_linux_workqueue_shutdown(void)')
shutdown_end=core.find('NvU32 nv_assign_gpu_count', shutdown_start)
shutdown=core[shutdown_start:shutdown_end]
if not (shutdown.find('current == thread') < shutdown.find('nv_linux_workqueue_state = NV_WQ_DRAINING') < shutdown.find('nv_linux_workqueue_state = NV_WQ_STOPPING')):
    raise SystemExit('shutdown self-check, DRAINING, and STOPPING ordering is wrong')
if shutdown.find('nv_linux_workqueue_flush()') > shutdown.find('nv_linux_workqueue_state = NV_WQ_STOPPING'):
    raise SystemExit('shutdown must run drain barriers before STOPPING')
if '(nv_linux_workqueue_state == NV_WQ_DRAINING) ||' not in shutdown:
    raise SystemExit('DRAINING shutdown callers must wait instead of becoming owners')
if shutdown.count('kthread_stop(thread)') != 1:
    raise SystemExit('exactly one shutdown path may call kthread_stop')
if 'nv_linux_workqueue_shutdown_result' in shutdown:
    raise SystemExit('shutdown result handoff must not use a mutable global result')
if 'nv_linux_workqueue_completed_sequence ==' not in shutdown or 'nv_linux_workqueue_next_sequence' not in shutdown:
    raise SystemExit('shutdown quiescence must compare completed and next sequence')
if shutdown.find('completed_sequence ==') > shutdown.find('nv_linux_workqueue_state = NV_WQ_STOPPING'):
    raise SystemExit('stable sequence quiescence must be checked before STOPPING')
for text in ['NV_WQ_UNINITIALIZED', 'NV_WQ_INITIALIZING', 'NV_WQ_DRAINING', 'NV_WQ_STOPPING', 'NV_WQ_STOPPED', 'nv_linux_workqueue_generation', 'nv_linux_workqueue_generation_done', 'wait_event(nv_linux_workqueue_shutdown_wait', 'nv_linux_workqueue_initializing_done', 'wake_up_all(&nv_linux_workqueue_shutdown_wait)', 'nv_linux_workqueue_thread = NULL', 'return -EDEADLK;', 'return 0;']:
    if text not in shutdown:
        raise SystemExit(f'shutdown state machine missing {text}')
rm_fail_start=core.find('if (!rm_init_rm(sp))')
rm_fail_end=core.find('// init the nvidia control device', rm_fail_start)
rm_fail=core[rm_fail_start:rm_fail_end]
order(rm_fail, 'WARN_ON_ONCE(nv_linux_workqueue_shutdown() != 0)', 'nv_kmem_cache_free_stack(sp);', 'rm_init_rm failure frees stack before queue shutdown')
order(rm_fail, 'WARN_ON_ONCE(nv_linux_workqueue_shutdown() != 0)', 'NV_KMEM_CACHE_DESTROY(nvidia_stack_t_cache);', 'rm_init_rm failure destroys stack cache before queue shutdown')
failed4_start=core.find('failed4:')
failed4_end=core.find('failed5:', failed4_start)
failed4=core[failed4_start:failed4_end]
order(failed4, 'WARN_ON_ONCE(nv_linux_workqueue_shutdown() != 0)', 'nv_lock_destroy_locks(sp, nv);', 'later init rollback destroys locks before queue shutdown')
order(failed4, 'WARN_ON_ONCE(nv_linux_workqueue_shutdown() != 0)', 'rm_shutdown_rm(sp);', 'later init rollback shuts RM down before queue shutdown')
exit_start=core.find('void nvidia_exit_module(void)')
exit_end=core.find('module_exit(nvidia_exit_module);', exit_start)
exit_body=core[exit_start:exit_end]
order(exit_body, 'WARN_ON_ONCE(nv_linux_workqueue_shutdown() != 0)', 'nv_lock_destroy_locks(sp, nv);', 'module exit destroys locks before queue shutdown')
order(exit_body, 'WARN_ON_ONCE(nv_linux_workqueue_shutdown() != 0)', 'rm_shutdown_rm(sp);', 'module exit shuts RM down before queue shutdown')
order(exit_body, 'WARN_ON_ONCE(nv_linux_workqueue_shutdown() != 0)', 'NV_KMEM_CACHE_DESTROY(nvidia_stack_t_cache);', 'module exit destroys stack cache before queue shutdown')
for name in ['counted drain was rejected', 'Work object and callback ABI', 'Flush-barrier and wait-predicate semantics', 'Single-thread serialization and scope', 'nvidia-modeset']:
    if name not in audit:
        raise SystemExit(f'{name} missing from audit')
PY

compile_probe() {
    mode=$1
    cat > "$work/probe-$mode.c" <<'CHEAD'
#include <stddef.h>
#define NV_FALSE 0
#define NV_TRUE 1
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
echo compile-probe-2
compile_probe 2
echo compile-probe-3
compile_probe 3

echo state-model
cc -Wall -Werror "$repo/tests/core-workqueue-state-model.c" -o "$work/state-model"
"$work/state-model"

echo selftest-compile
cc -DNV_WORKQUEUE_SELFTEST -Wall -Werror "$repo/tests/core-workqueue-selftest.c" -o "$work/core-workqueue-selftest"
"$work/core-workqueue-selftest"

echo inventory
rg -n 'NV_WORKQUEUE_SCHEDULE\(' "$prepared/nvidia" --glob '*.c' > "$work/core-workqueue-schedule.txt"
grep -F 'nvidia/os-interface.c' "$work/core-workqueue-schedule.txt" >/dev/null
grep -F 'nvidia/nv-gvi.c' "$work/core-workqueue-schedule.txt" >/dev/null
test "$(wc -l < "$work/core-workqueue-schedule.txt")" -eq 2

rg -n 'NV_WORKQUEUE_FLUSH(_STATUS)?\(' "$prepared/nvidia" --glob '*.c' > "$work/core-workqueue-flush.txt"
grep -F 'nvidia/os-interface.c' "$work/core-workqueue-flush.txt" >/dev/null
grep -F 'nvidia/nv.c' "$work/core-workqueue-flush.txt" >/dev/null
grep -F 'nvidia/nv-gvi.c' "$work/core-workqueue-flush.txt" >/dev/null
test "$(wc -l < "$work/core-workqueue-flush.txt")" -eq 4

rg -n '^[[:space:]]*flush_scheduled_work\(\);' "$prepared/nvidia-modeset" >"$work/modeset-flush.txt"
test "$(wc -l < "$work/modeset-flush.txt")" -eq 2

echo repository-hygiene
if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    status=$(git -C "$repo" status --short)
    if printf '%s\n' "$status" |
       grep -E '\.(rej|ko|ko\.zst|deb|dsc|changes|buildinfo)$|NVIDIA-Linux-.*\.run|\.so$'
    then
        echo 'generated or proprietary artifact is staged or present in repository status' >&2
        exit 1
    fi
fi
