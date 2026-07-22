# Core NVIDIA workqueue drain API audit

This audit is scoped to the core `nvidia` module. Direct `flush_scheduled_work()`
call sites in `nvidia-modeset` are intentionally unchanged and remain a separate
follow-up.

## Why the counted drain was rejected

The earlier counted-drain implementation signalled completion from inside
`os_execute_work_item()` and `nv_gvi_kern_bh()`. That was not equivalent to
`flush_scheduled_work()`: a waiter could resume before the callback returned to
the execution wrapper, while NVIDIA code was still on the worker stack. A global
zero-counter drain also changed the old snapshot-style flush into "wait until all
counted NVIDIA work happens to be idle", which was not proven safe for hidden RM
producers or future submissions.

## Selected queue architecture

The replacement uses a module-global, single-threaded, kthread-backed FIFO queue
for core `NV_WORKQUEUE_SCHEDULE()` users. It preserves the original
`nv_work_t`/`nv_task_t` containment model: `nv_work_t` still contains `task`, and
two-argument callbacks recover the wrapper with `container_of(task, nv_work_t,
task)`. The queue is initialized during core module initialization and stopped
during failure rollback and module exit.

The queue uses one spin lock for list, sequence, running, stopping, and thread
pointer state; one worker wait queue for accepted work; and one flush wait queue
for barrier completion. A flush snapshots the latest accepted sequence and waits
until the worker has invoked each callback through that sequence, the callback
has returned, queue-owned cleanup has run, and only then the completed sequence
has been published.

## Source-site inventory

| function | work object | dynamic/static | producer | callback | duplicate scheduling | callback requeue | locks held | producer shutdown | state destroyed after flush | required ordering |
|---|---|---|---|---|---|---|---|---|---|---|
| `os_queue_work_item()` | allocated `nv_work_t` containing `task` | dynamic | proprietary RM via OS interface | `os_execute_work_item()` | not expected for newly allocated wrapper | possible only through RM after callback starts | none visible | queue rejects submissions after shutdown starts | RM close/disable state | accepted work through flush barrier must return from callback and finish queue-owned free before flush returns |
| `nv_gvi_kern_isr()` | `nvl->work.task` | static per device | GVI interrupt bottom-half request | `nv_gvi_kern_bh()` | coalesced while already queued, matching `schedule_work()` pending coalescing; one requeue may be accepted while running | no callback self-requeue found in visible source | interrupt context | GVI suspend/teardown stops interrupt producer before freeing GVI state | IRQ/GVI private state | accepted GVI bottom halves through flush barrier must return before teardown continues |

Core flush sites:

| function | execution context | required ordering |
|---|---|---|
| `os_flush_work_queue()` | passive only (`NV_MAY_SLEEP()`) | sequence barrier for all core work accepted before the call |
| `nv_stop_device()` GVI path | last close; `nvl->ldata_lock` held by caller comment | GVI BH callbacks accepted before the barrier must finish before IRQ/device teardown |
| `nv_remove()` GVI detach path | PCI remove | GVI BH callbacks accepted before the barrier must finish before private-state free |
| `nv_gvi_kern_suspend()` | PM suspend | GVI BH callbacks accepted before the barrier must finish before suspend continues |

## Work object and callback ABI

`nv_task_t` is the queue node. `nv_work_t` remains the wrapper containing
`nv_task_t task` and `void *data`, preserving `work->task` users. Macro
parameters use `_tq`, `_handler`, and `_data`-style names so preprocessing cannot
rewrite member names. For `NV_INIT_WORK_ARGUMENT_COUNT == 2`, the worker invokes
`task->handler(task)` and `NV_WORKQUEUE_UNPACK_DATA(task)` uses `container_of`.
For `NV_INIT_WORK_ARGUMENT_COUNT == 3`, the worker invokes
`task->handler(task->handler_data)`.

## Scheduling semantics

`NV_WORKQUEUE_INIT()` initializes the task list node, callback, stored callback
data, optional owned-allocation pointer, queued/running sequence fields, and
queued/running flags. `NV_WORKQUEUE_SCHEDULE()` rejects submissions after
shutdown starts. Otherwise, it accepts an item only if it is not already queued,
assigns the next queued sequence, appends it to the FIFO under the spin lock, and
wakes the worker wait queue after publishing the list update. A static item
submitted while queued is coalesced. A static item submitted while its callback
is running and not already queued is accepted as a later FIFO item. The worker
copies `queued_sequence` to a separate `running_sequence` when dequeuing so a
requeue of the same static object cannot overwrite the sequence being completed.

Dynamic `os_queue_work_item()` wrappers store the exact enclosing allocation in
`task.owned_allocation` before scheduling. If shutdown rejects submission, the
wrapper is freed immediately and `NV_ERR_INVALID_STATE` is returned.

## Execution and cleanup semantics

The worker removes one FIFO item under the queue lock, drops the lock, invokes
the existing callback, and waits for that callback to return. It then saves the
running sequence and exact owned-allocation pointer under the lock, clears the
running state, clears `owned_allocation` if present, drops the lock, performs
queue-owned free, reacquires the lock to advance `completed_sequence`, and wakes
flush waiters. It never dereferences a task after freeing the allocation that
contains it.

Because the queue is single-threaded FIFO and completion uses the saved running
sequence, no later accepted sequence can complete before an earlier accepted
sequence, including static work requeued while the previous callback is running.

## Flush-barrier and wait-predicate semantics

`NV_WORKQUEUE_FLUSH()` snapshots `next_sequence` under the queue lock and waits
on a separate flush wait queue until a helper has acquired the same lock and
observed `completed_sequence >= barrier`. Later submissions receive higher
sequence numbers and do not delay an older flush. Concurrent flushers are safe
because each uses its own snapshot and the shared completed sequence advances in
FIFO worker order.

The worker wait predicate also acquires the spin lock before checking list
emptiness. Enqueue publishes list and sequence state before dropping the lock and
waking the worker wait queue, preventing lost wakeups with the wait-event
predicate recheck.

## Shutdown and initialization semantics

Queue initialization is attempted exactly once after the stack cache and init
stack are available. If later module initialization fails, rollback calls
`nv_linux_workqueue_shutdown()` before the stack cache is destroyed. Module exit
calls shutdown after RM shutdown and before compatibility ioctl unregister and
stack-cache teardown. Shutdown first sets `stopping` under the lock so new
submissions are rejected, wakes the worker wait queue, flushes all accepted work,
then calls `kthread_stop()` and clears the thread pointer under the lock after
thread exit.

A flush from the queue thread is diagnosed and returns instead of silently
deadlocking the single worker.

## Single-thread serialization and scope

The queue is module-global, preserving the old core `flush_scheduled_work()`
scope rather than creating per-device flushes. Later NVIDIA branches introduced
kthread queue infrastructure (`nv-kthread-q.c`) for NVIDIA-owned asynchronous
execution, but exact branch semantics and proprietary RM recursion behavior still
require build/runtime validation. This patch therefore keeps the conservative
old global scope: one device's earlier accepted core work can delay another
flush. Visible open source shows no callback calling `os_flush_work_queue()` and
no GVI callback self-requeue, but visible-source absence is not treated as proof
for proprietary RM behavior; the defensive worker-flush check prevents silent
self-deadlock.

## Lock, deadlock, and memory ordering

The queue lock protects the list, sequence assignment, shutdown flag, thread
pointer, running state, and completion sequence. Callbacks run without the queue
lock, preventing queue-management/callback lock inversion. Spin lock
acquire/release and wait-queue predicate rechecks provide ordering for queue
metadata; callback payload ordering remains the producer/consumer's
responsibility as before.

## Symbol-export audit

| symbol/API | Bookworm 6.1 | Ubuntu 6.8.0-136 | Trixie 6.12 | classification |
|---|---|---|---|---|
| `kthread_create_on_node` | requires exact Module.symvers confirmation | requires exact target Module.symvers confirmation | requires exact Module.symvers confirmation | intended `EXPORT_SYMBOL`, final authority MODPOST |
| `kthread_stop` | requires exact Module.symvers confirmation | requires exact target Module.symvers confirmation | requires exact Module.symvers confirmation | intended `EXPORT_SYMBOL`, final authority MODPOST |
| `wake_up_process` | requires exact Module.symvers confirmation | requires exact target Module.symvers confirmation | requires exact Module.symvers confirmation | used to start the new kthread, final authority MODPOST |
| `__wake_up` via wait/wake macros | requires exact Module.symvers confirmation | requires exact target Module.symvers confirmation | requires exact Module.symvers confirmation | final authority MODPOST |
| `schedule_timeout`/scheduler wait internals | macro path only if emitted | macro path only if emitted | macro path only if emitted | final authority undefined-symbol audit |
| `alloc_workqueue`, `alloc_ordered_workqueue`, `create_singlethread_workqueue`, `destroy_workqueue`, `flush_work`, `cancel_work_sync` | not used | not used | not used | prohibited/rejected |

Exact Ubuntu 6.8, Bookworm, and Trixie undefined-symbol audits must be completed
from built `nvidia.ko` artifacts and their exact `Module.symvers`; no completed
Ubuntu 6.8 build result is claimed here.

## Remaining limitations

`nvidia-modeset` still contains direct system-workqueue flushes and is out of
scope for this core-only patch. No K620 runtime test has been performed; the
issue is not confirmed fixed until controlled runtime testing shows no core
system-wide workqueue warning, no bad-frame-pointer unwind warning, no Xid or
adapter failure, clean unload, and restoration to `nouveau`.
