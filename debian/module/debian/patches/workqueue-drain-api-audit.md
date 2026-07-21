# Core NVIDIA workqueue drain API audit

This audit is intentionally scoped to the core `nvidia` module. The direct
`flush_scheduled_work()` calls in `nvidia-modeset` are unchanged and remain a
separate follow-up.

## Original behavior and Linux 6.8 warning

Pristine NVIDIA 367.134 maps core `NV_WORKQUEUE_SCHEDULE(work)` to
`schedule_work(work)` and `NV_WORKQUEUE_FLUSH()` to `flush_scheduled_work()`.
On Ubuntu 24.04 Linux `6.8.0-136-generic`, the core close path reports:
`WARNING: Flushing system-wide workqueues will be prohibited in near future`,
through `__warn_flushing_systemwide_wq`, `os_flush_work_queue [nvidia]`, and
`rm_disable_adapter [nvidia]` when `nvidia-smi` closes the device.

## Source-site inventory

Fully patched source inspection found the following core scheduling sites:

| site | work item | callback | dynamic/static | producer |
|---|---|---|---|---|
| `nvidia/os-interface.c:os_queue_work_item()` | allocated `nv_work_t` | `os_execute_work_item()` | dynamic | RM via `os_queue_work_item()` |
| `nvidia/nv-gvi.c:nv_gvi_kern_isr()` | `nvl->work.task` | `nv_gvi_kern_bh()` | static per device | GVI interrupt bottom-half request |

Core flush sites:

| flush caller | execution context | locks held | producer-quiescing action | can producer race | can callback requeue | state destroyed after flush | required semantics |
|---|---|---|---|---|---|---|---|
| `nvidia/os-interface.c:os_flush_work_queue()` | passive only (`NV_MAY_SLEEP()`) | RM caller dependent | RM is expected to stop relevant producers before requesting OS drain | no independent producer identified for close-time RM drain after RM quiesce | none identified | RM close/disable state | wait until accepted core NVIDIA work is idle |
| `nvidia/nv.c:nv_stop_device()` GVI path | last close, passive; comment says `nvl->ldata_lock` held | `ldata_lock` | `rm_shutdown_gvi_device()` before flush | ISR producer quiesced before `free_irq()` | no | IRQ and GVI device state | drain accepted GVI BH work before IRQ/state teardown |
| `nvidia/nv.c:nv_remove()` GVI detach path | PCI remove, passive | no teardown lock found around flush | device shutdown and detach path reached after device removal has stopped normal producers | no normal independent producer identified | no | GVI private state | drain accepted GVI BH work before private-state free |
| `nvidia/nv-gvi.c:nv_gvi_kern_suspend()` | PM suspend, passive | no lock held across flush in visible code | sets `NV_FLAG_GVI_IN_SUSPEND` before flush after `rm_shutdown_gvi_device()` | ISR path tests suspend flag and stops submitting | no | suspend transition state | drain accepted GVI BH work before suspend |

Callbacks and return paths:

* `os_execute_work_item()` has two exits: stack-allocation failure and normal
  completion after `rm_execute_work_item()`, `os_free_mem(work)`, and stack
  free. Both paths complete accounting exactly once. The stack-allocation
  failure path appears to leave the dynamically allocated `nv_work_t` allocated;
  this patch does not change ownership because the leak is pre-existing and
  orthogonal to replacing the global flush. It is documented as a follow-up.
* `nv_gvi_kern_bh()` has one visible return path after `rm_gvi_bh()` and now
  completes accounting exactly once.

No callback-generated or self-requeued work was found in the core source. The
GVI ISR may call `schedule_work()` again while static work is running; Linux
workqueue semantics accept that as a later execution, and the wrapper accounts
it as a separate accepted instance.

## Selected design

The patch retains the system workqueue but counts only accepted core NVIDIA
work items. `NV_WORKQUEUE_SCHEDULE()` increments an atomic count before calling
`schedule_work()`. If `schedule_work()` rejects a duplicate pending submission,
the speculative count is removed immediately. Every accepted callback exit calls
`NV_WORKQUEUE_COMPLETE()`. `NV_WORKQUEUE_FLUSH()` waits for the count to reach
zero with a wait queue.

A simple zero-counter drain is sufficient for the audited core flush sites
because each visible teardown/suspend caller quiesces the relevant producers
before the flush, and the general RM flush is a passive drain invoked after RM
has stopped the relevant RM producers. The implementation still correctly
counts accepted requeues that occur while a callback is running: the count is
incremented before the requeue is accepted and decremented by the later callback
execution.

## Duplicate scheduling and requeue analysis

`schedule_work()` returns false when work is already pending. Such duplicate
submissions do not create a workqueue execution and are not counted. If a static
GVI item is scheduled while its callback is running and Linux accepts the new
pending execution, the wrapper records a new count before the kernel can expose
it to a concurrent flush. No accepted work item is invisible to a concurrent
flush.

## Lock, deadlock, memory-ordering, and module-instance analysis

Flushers wait only on the module-local wait queue and do not take a callback
lock. The visible GVI close flush occurs before `free_irq()` and after
`rm_shutdown_gvi_device()`, while the suspend path sets the suspend flag before
flushing. No audited flush site runs from an accounted callback. Atomic
increment/decrement plus `wait_event()` condition rechecking provide the needed
visibility for the drain count; no payload data is transferred through the
counter. The count and wait queue are core-module globals, matching the single
loaded proprietary module instance and the prior global core flush behavior.

## Rejected designs

* Private workqueue allocation was rejected because `alloc_workqueue()` and
  `destroy_workqueue()` are GPL-only on the target kernel families and are
  explicitly out of scope for this proprietary module.
* `flush_work()` and `cancel_work_sync()` were not used because no exact target
  export evidence was required or introduced for this smaller counted-drain
  design.
* A kthread-backed queue was rejected as disproportionate after the audited
  producers were shown to be quiesced at flush sites.

## Symbol-export matrix

| symbol/API | Linux 6.1 | Linux 6.8 | Linux 6.12 | classification |
|---|---|---|---|---|
| `schedule_work()` | inline wrapper around exported queueing path already used by driver | same | same | pre-existing callable |
| `atomic_inc`, `atomic_dec_and_test`, `atomic_read` | inline/arch primitive | inline/arch primitive | inline/arch primitive | no external reference expected |
| `wait_event()` | macro using wait-queue helpers | same | same | helper references verified by MODPOST |
| `wake_up_all()` | macro/helper using exported wake-up path | same | same | helper references verified by MODPOST |
| `alloc_workqueue()` / `destroy_workqueue()` | GPL-only export on audited kernels | GPL-only export on target Ubuntu kernel | GPL-only export on audited kernels | rejected |

Final authority is the proprietary module `MODPOST` and the undefined-symbol
audit for `nvidia.ko`.

## Test results and remaining limitations

Repository static tests verify that the patch is present in `series.in`, the
full series applies without production `.rej`, the core macro no longer expands
to `flush_scheduled_work()`, prohibited private-workqueue APIs are absent, core
scheduling/callback/flush sites are enumerated, modeset flushes are unchanged
and out of scope, and generated/proprietary artifacts are not staged. Full
Bookworm, Trixie, and Ubuntu `6.8.0-136-generic` build results are recorded in
external logs.

Remaining limitations: the direct modeset system-wide flushes are unchanged;
the dynamic `nv_work_t` allocation on `os_execute_work_item()` stack-allocation
failure appears to be a separate pre-existing leak follow-up; no K620 runtime
load test was performed.
