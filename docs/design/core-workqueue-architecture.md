# Core workqueue architecture decision record

## Context

The core `nvidia` module in NVIDIA legacy 367 used the Linux system workqueue
for visible RM work wrappers and GVI bottom halves, then used
`flush_scheduled_work()` at core flush sites. Linux 6.8 warns that flushing
system-wide workqueues will be prohibited. This PR keeps `nvidia-modeset` out of
scope.

## Option A: current single global queue

Advantages:

- closest replacement for the old global flush scope;
- small implementation with one FIFO sequence space;
- straightforward callback-return, cleanup, and shutdown ordering.

Risks:

- serializes unrelated RM and GVI work;
- hidden RM callback dependencies can deadlock if a callback waits for another
  queued callback;
- global work from one device can delay another device's teardown.

## Option B: separate RM and GVI queues

Advantages:

- GVI bottom halves do not block generic RM work;
- reduces cross-subsystem dependency risk;
- per-subsystem diagnostics could be clearer.

Risks:

- no longer reproduces one global core flush scope;
- every flush site must identify exactly which queues it owns;
- hidden RM ordering might rely on global execution and flush ordering.

## Option C: closer backport of later `nv_kthread_q`

Advantages:

- closer to an authoritative NVIDIA design;
- supports caller-provided queues and established completion-item flush shape;
- later sources include a self-test structure.

Risks:

- larger backport surface;
- requires adapting 367 callback ABIs and dynamic wrapper ownership;
- proprietary 367 RM may not expose queue arguments;
- still does not prove hidden 367 RM wait or shutdown behavior.

## Current recommendation

Retain Option A only as a draft implementation until review and controlled K620
runtime evidence show no RM/GVI serialization deadlock, no system-wide workqueue
warning, no bad-frame-pointer unwind warning, no Xid/adapter failure, and clean
unload/restoration to `nouveau`. Evidence of callback wait deadlock, device
cross-talk, or RM shutdown submissions rejected in `STOPPING` should trigger a
redesign toward Option B or Option C.

## Optional diagnostics follow-up

A controlled debug build should add disabled-by-default counters under a macro
such as `NV_WORKQUEUE_DIAGNOSTICS`: accepted schedules, coalesced schedules,
state-rejected schedules, dynamic one-shot rejections, callbacks started,
callbacks completed, current and maximum queue depth, flush calls, shutdown-owner
elections, shutdown waiters, shutdown drain-loop iterations, and worker wait
interruptions. Counter updates should happen under `nv_linux_workqueue_lock` or
through explicitly selected atomics, and a compact dump routine should only be
called by a controlled debug path. This PR documents the design but keeps
production behavior and ABI unchanged.
