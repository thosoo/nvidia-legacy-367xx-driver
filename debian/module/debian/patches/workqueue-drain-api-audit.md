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

The queue uses one spin lock for list, sequence, running, lifecycle state, and
thread pointer state; one non-interruptible worker wait queue for accepted work;
one flush wait queue for barrier completion; and one shutdown wait queue for
concurrent shutdown serialization. A flush snapshots the latest accepted sequence and waits
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
data, optional owned-allocation pointer, queued/running sequence fields, queued/running flags, and a `requeueable` flag. `NV_WORKQUEUE_SCHEDULE()` rejects submissions after
shutdown starts. Otherwise, it accepts an item only if it is not already queued and either is requeueable or has never been accepted before, assigns the next queued sequence, appends it to the FIFO under the spin lock, and
wakes the worker wait queue after publishing the list update. A static item
submitted while queued is coalesced. A static item submitted while its callback
is running and not already queued is accepted as a later FIFO item. The worker
copies `queued_sequence` to a separate `running_sequence` when dequeuing so a
requeue of the same static object cannot overwrite the sequence being completed.

Dynamic `os_queue_work_item()` wrappers set `requeueable` to false and store the exact enclosing allocation in
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

`NV_WORKQUEUE_FLUSH_STATUS()` executes two FIFO sequence barriers. Each barrier
snapshots `next_sequence` under the queue lock and waits on a separate flush wait
queue until a helper has acquired the same lock and observed
`completed_sequence >= barrier`. The first barrier drains work accepted before
the flush call; the second mirrors later NVIDIA `nv_kthread_q_flush()` behavior
and includes one wave of callback-generated or self-requeued work accepted while
callbacks ahead of the first barrier were running. Later independent submissions
after the second snapshot receive higher sequence numbers and do not delay that
flush. Concurrent flushers are safe because each uses its own snapshots and the
shared completed sequence advances in FIFO worker order.

The worker uses `wait_event()` rather than `wait_event_interruptible()` because no signal-handling behavior is required for this kernel thread. The worker wait predicate also acquires the spin lock before checking list
emptiness. Enqueue publishes list and sequence state before dropping the lock and
waking the worker wait queue, preventing lost wakeups with the wait-event
predicate recheck.

## Shutdown and initialization semantics

Module-init failure ordering: queue initialization is attempted exactly once after the stack cache and init stack are available; if `rm_init_rm()` fails, `WARN_ON_ONCE(nv_linux_workqueue_shutdown() != 0)` diagnoses a violated lifecycle precondition (`current != nvidia-wq`); on success, shutdown drains accepted work and stops the worker before freeing the init stack or destroying `nvidia_stack_t_cache`, while on failure the rollback returns before destroying callback dependencies. Later rollback ordering: queue shutdown runs before NVIDIA locks are destroyed and before `rm_shutdown_rm()`. Module-exit ordering: queue shutdown runs before RM shutdown and stack-cache teardown. Shutdown uses the explicit states `NV_WQ_UNINITIALIZED`, `NV_WQ_INITIALIZING`, `NV_WQ_RUNNING`, `NV_WQ_DRAINING`, `NV_WQ_STOPPING`, and `NV_WQ_STOPPED`. Under the queue lock, initialization transitions `UNINITIALIZED/STOPPED -> INITIALIZING` before kthread creation, so a second initializer is rejected and shutdown during initialization waits for creation to finish or fail. Shutdown transitions `RUNNING -> DRAINING`, leaves scheduling enabled for callback-generated or static self-requeued work during the two barriers, then transitions to `STOPPING` only after the drain loop observes an empty queue. Callers observing `DRAINING` or `STOPPING` are waiters, not owners: they snapshot `nv_linux_workqueue_generation`, wait for the owner to publish a new generation, and then return the owner's `nv_linux_workqueue_shutdown_result`. This avoids the ABA case where a waiter could observe `STOPPED`, miss a wake, and sleep across a restart. Shutdown-before-init and shutdown-after-stop return success. The sole owner publishes the thread pointer clear, `STOPPED` state, result, and generation under the lock, then wakes shutdown waiters. Shutdown from the worker thread is detected before mutating state and returns `-EDEADLK`; status-returning lifecycle rollback paths return before destroying dependencies on failure. In module exit, the only defined failure is worker-thread recursion; module exit runs from the module-removal task, not `nvidia-wq`, so it calls shutdown as a no-fail lifecycle operation and does not use an early return as an unload-abort mechanism.

A flush from the queue thread is diagnosed and returns `-EDEADLK` instead of silently deadlocking the single worker. `os_flush_work_queue()` maps that to `NV_ERR_ILLEGAL_ACTION`. Direct GVI teardown/removal/suspend sites are user-close, PCI driver-core, and PM-core contexts respectively, not `nvidia-wq` callback context. `nv_stop_device()` treats `rm_shutdown_gvi_device()` as the producer-quiescence operation, flushes after it, and releases the IRQ only after the flush. `nv_remove()` flushes before GVI detach/private-state destruction, and `nv_gvi_kern_suspend()` flushes before `rm_gvi_suspend()`; void stop/remove paths use non-fatal invariant diagnostics without pretending a return can abort PCI/module teardown; the status-returning suspend path still propagates failure through its existing error path.

## Single-thread serialization and scope

The queue is module-global, preserving the old core `flush_scheduled_work()`
scope rather than creating per-device flushes. NVIDIA open GPU kernel modules
525.60.11 contain `kernel-open/nvidia/nv-kthread-q.c`. That implementation says each `nv_kthread_q` instance is FIFO and serviced by exactly one kthread; `_main_loop()` removes the first list item and invokes its function outside the lock; `nv_kthread_q_schedule_q_item()` rejects scheduling after `main_loop_should_exit` and otherwise coalesces only if the q_item list node is already pending; `nv_kthread_q_flush()` schedules a completion item and performs two raw flushes specifically for a self-rescheduling item; and `nv_kthread_q_stop()` calls `nv_kthread_q_flush()` before setting `main_loop_should_exit` and calling `kthread_stop()`, so scheduling is not disabled during the stop drain. This supports the single-thread FIFO and double-barrier shape, but it does not prove that 367 proprietary RM cannot synchronously wait for another queued callback, nor does it prove that all generic RM and GVI work should share one global queue. This PR therefore remains draft pending reviewer confirmation of RM recursion/wait behavior. The current patch keeps old global flush scope: one device's earlier accepted core work can delay another flush. Visible 367 open source shows no callback calling `os_flush_work_queue()` and no GVI callback self-requeue, but visible-source absence is not treated as proof for proprietary RM behavior; the defensive worker-flush check prevents silent self-deadlock.

## Lifecycle state behavior

| state | init | schedule | flush | shutdown owner/waiter | worker-thread shutdown |
|---|---|---|---|---|---|
| `UNINITIALIZED` | may become `INITIALIZING` | rejected | empty barrier | no-op success | `-EDEADLK` only if thread pointer somehow matches |
| `INITIALIZING` | second init rejected | rejected | empty/current barrier | waits for initialization generation, then retries | not applicable before thread publish |
| `RUNNING` | rejected | accepted subject to queued/requeueable rules | two barriers | first caller becomes owner and sets `DRAINING` | returns `-EDEADLK` |
| `DRAINING` | rejected | accepted for callback-generated/static requeue work after producer quiescence | two barriers | additional callers wait on generation/result | returns `-EDEADLK` |
| `STOPPING` | rejected | rejected | should be empty after owner drain | additional callers wait on generation/result | returns `-EDEADLK` |
| `STOPPED` | may restart in a later module-instance path | rejected | empty barrier | no-op success | not applicable |

## RM shutdown ordering note

The queue still stops before `rm_shutdown_rm(sp)` so accepted callbacks cannot
run after RM global teardown, locks, or the stack cache have been destroyed. The
shutdown drain now leaves scheduling enabled in `NV_WQ_DRAINING`, matching later
NVIDIA stop ordering for callback-generated work before `STOPPING`, but any hidden
RM submission attempted after the final transition to `STOPPING` would still be
rejected with `NV_ERR_INVALID_STATE`. No visible 367 source calls
`os_queue_work_item()` from module-exit code, and authoritative open 525.60.11
queue code does not expose proprietary RM shutdown internals. Because proprietary
RM shutdown behavior is not fully visible, this remains an unresolved release
blocker rather than a proven-safe claim. A two-phase ordering (flush while RM is
live, run RM shutdown while the executor remains available, then final
drain/stop) must not be adopted unless it is proven that callbacks queued during
RM shutdown remain valid after RM shutdown begins.

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
| `kthread_create_on_node` | confirmed by package MODPOST | requires exact target Module.symvers confirmation | confirmed by package MODPOST | intended `EXPORT_SYMBOL`, final authority MODPOST |
| `kthread_stop` | confirmed by package MODPOST | requires exact target Module.symvers confirmation | confirmed by package MODPOST | intended `EXPORT_SYMBOL`, final authority MODPOST |
| `wake_up_process` | confirmed by package MODPOST | requires exact target Module.symvers confirmation | confirmed by package MODPOST | used to start the new kthread, final authority MODPOST |
| `__wake_up` via wait/wake macros | confirmed by package MODPOST | requires exact target Module.symvers confirmation | confirmed by package MODPOST | final authority MODPOST |
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
