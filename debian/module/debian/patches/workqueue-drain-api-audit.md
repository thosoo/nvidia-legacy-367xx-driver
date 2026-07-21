# Core NVIDIA workqueue drain API audit

This audit is scoped to the core `nvidia` module. Direct `flush_scheduled_work()`
call sites in `nvidia-modeset` are intentionally unchanged and remain a separate
follow-up.

## Why the counted drain was rejected

The earlier counted-drain implementation signalled completion from inside
`os_execute_work_item()` and `nv_gvi_kern_bh()`. That was not equivalent to
`flush_scheduled_work()`: a waiter could resume before the Linux workqueue core
had received the callback return, while NVIDIA code was still on the worker
stack. A global zero-counter drain also changed the old snapshot-style flush into
"wait until all counted NVIDIA work happens to be idle", which was not proven
safe for hidden RM producers or future submissions.

## Selected queue architecture

The replacement uses a module-global, single-threaded, kthread-backed FIFO queue
for core `NV_WORKQUEUE_SCHEDULE()` users. The queue is initialized during core
module initialization and stopped during failure rollback and module exit. It
uses a spin lock for queue state, a wait queue for worker and flush wakeups, and
monotonic sequence numbers for flush barriers.

A flush snapshots the latest accepted sequence number and waits until the worker
has invoked each callback through that sequence, the callback has returned to the
queue wrapper, and queue-owned completion/cleanup has run. Work submitted after
the barrier receives a later sequence and does not delay that flush.

## Source-site inventory

Fully patched source inspection records these core scheduling sites:

| function | work object | dynamic/static | producer | callback | duplicate scheduling | callback requeue | locks held | producer shutdown | state destroyed after flush | required ordering |
|---|---|---|---|---|---|---|---|---|---|---|
| `os_queue_work_item()` | allocated `nv_work_t` | dynamic | proprietary RM via OS interface | `os_execute_work_item()` | not expected for newly allocated wrapper | possible only through RM after callback starts | none visible | queue rejects submissions after shutdown starts | RM close/disable state | accepted work through flush barrier must return from callback before flush returns |
| `nv_gvi_kern_isr()` | `nvl->work` | static per device | GVI interrupt bottom-half request | `nv_gvi_kern_bh()` | coalesced while already queued, matching `schedule_work()` pending coalescing; one requeue may be accepted while running | no callback self-requeue found | interrupt context | GVI suspend/teardown stops interrupt producer before freeing GVI state | IRQ/GVI private state | accepted GVI bottom halves through flush barrier must return before teardown continues |

Core flush sites:

| function | execution context | required ordering |
|---|---|---|
| `os_flush_work_queue()` | passive only (`NV_MAY_SLEEP()`) | flush barrier for all core work accepted before the call |
| `nv_stop_device()` GVI path | last close; `nvl->ldata_lock` held by caller comment | GVI BH callbacks accepted before the barrier must finish before IRQ/device teardown |
| `nv_remove()` GVI detach path | PCI remove | GVI BH callbacks accepted before the barrier must finish before private-state free |
| `nv_gvi_kern_suspend()` | PM suspend | GVI BH callbacks accepted before the barrier must finish before suspend continues |

Callbacks:

* `os_execute_work_item()` now executes RM dynamic work and frees only the stack;
  the queue wrapper owns and frees the dynamic `nv_work_t` after the callback
  returns. This also fixes the pre-existing stack-allocation failure leak because
  every dynamic wrapper is freed by queue-owned cleanup after callback return.
* `nv_gvi_kern_bh()` remains a static-work callback; no callback-internal queue
  completion signal is used.

## Scheduling semantics

`NV_WORKQUEUE_INIT()` initializes a queue item with callback, data, sequence,
queued/running sequence fields, queued/running flags, and dynamic ownership flag. `NV_WORKQUEUE_SCHEDULE()`
rejects submissions after shutdown starts. Otherwise, it accepts an item only if
it is not already queued, assigns the next queued sequence, appends it to the FIFO, and
wakes the worker. A static item submitted while queued is coalesced, preserving
`schedule_work()` duplicate-pending semantics. A static item submitted while its
callback is running and not already queued is accepted as a later FIFO item,
matching the observable requeue-while-running behavior of `schedule_work()`.

Dynamic `os_queue_work_item()` wrappers are marked queue-owned after
initialization. If shutdown rejects submission, the wrapper is freed immediately
and `NV_ERR_INVALID_STATE` is returned.

## Execution semantics

The worker removes one FIFO item under the queue lock, drops the lock, invokes
the existing callback, waits for that callback to return, then reacquires the
lock to mark the item's sequence complete. No callback runs while holding the
queue lock. Dynamic wrappers are freed only after callback return and queue-owned
completion wakeup.

Because the queue is single-threaded FIFO and copies each queued sequence to a separate running-sequence field when dequeuing, sequence comparison is safe: no later accepted sequence can complete before an earlier accepted sequence, including static work requeued while its previous callback is running.

## Flush-barrier semantics

`NV_WORKQUEUE_FLUSH()` snapshots `next_sequence` under the queue lock and waits
until `completed_sequence >= barrier`. Concurrent flushers are safe because each
uses its own snapshot and the shared completed sequence only advances in FIFO
worker order. Later submissions receive higher sequence numbers and do not delay
an older flush.

## Shutdown semantics

Shutdown sets the stopping flag first, so new submissions are rejected. It then
flushes accepted work and calls `kthread_stop()`, which wakes and waits for the
worker thread to exit. The queue thread pointer is cleared only after the stop
returns. Failure rollback calls shutdown after queue initialization if later
module initialization fails.

The audited source contains no flush from within a queue callback. Such a call
would be a bug because the single worker could not make progress on itself.

## Queue scope and module instances

The queue is module-global, preserving the old core `flush_scheduled_work()`
scope, which synchronized all core NVIDIA work rather than per-device work. This
means one device's earlier accepted core work can delay another device's flush,
which matches the conservative global synchronization behavior being replaced.
Optional NVIDIA module-instance builds still get one queue per loaded module
image because the state is module static.

## Lock, deadlock, and memory ordering

The queue lock protects the list, sequence assignment, shutdown flag, and
completion sequence. Flush waits do not hold device locks inside the queue, and
callbacks run without the queue lock, preventing queue-management/callback lock
inversion. Spin lock acquire/release and wait-queue condition rechecks provide
ordering for queue metadata; callback payload memory ordering remains the
callback producer/consumer's responsibility as before.

## Symbol-export audit

| symbol/API | Bookworm 6.1 | Ubuntu 6.8.0-136 | Trixie 6.12 | classification |
|---|---|---|---|---|
| `kthread_create_on_node` | requires Module.symvers confirmation | requires exact target Module.symvers confirmation | requires Module.symvers confirmation | intended `EXPORT_SYMBOL`, final authority MODPOST |
| `kthread_stop` | requires Module.symvers confirmation | requires exact target Module.symvers confirmation | requires Module.symvers confirmation | intended `EXPORT_SYMBOL`, final authority MODPOST |
| `wake_up_process` | requires Module.symvers confirmation | requires exact target Module.symvers confirmation | requires Module.symvers confirmation | intended `EXPORT_SYMBOL`, final authority MODPOST |
| `__wake_up` via wait/wake macros | requires Module.symvers confirmation | requires exact target Module.symvers confirmation | requires Module.symvers confirmation | final authority MODPOST |
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
