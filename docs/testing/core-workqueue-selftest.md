# Core workqueue optional self-test design

This PR does not enable an in-kernel self-test in production packages. A future
`NV_WORKQUEUE_SELFTEST` build should compile a separate internal test source
that calls the actual queue API after module initialization but before hardware
binding. The test must remain disabled unless `NV_WORKQUEUE_SELFTEST` is defined.

Planned behavioral cases:

- basic init, schedule, flush, repeated flush, and stop;
- multiple concurrent producer threads that submit distinct static items;
- duplicate scheduling of the same static item while queued;
- static self-requeue while running, guarded by a stop-rescheduling flag;
- double-barrier flush that waits for one callback-generated wave;
- concurrent shutdown callers with one elected owner;
- dynamic one-shot cleanup after callback return;
- rejected submission after `STOPPING` is visible;
- restart after `STOPPED` in a controlled test-only lifecycle.

The compile-only repository scaffold is `tests/core-workqueue-selftest.c`, built
with `-DNV_WORKQUEUE_SELFTEST` by `tests/core-workqueue-drain.sh`. It is an
original userspace approximation of the intended cases; it is not a substitute
for a real kernel self-test or the controlled K620 runtime test.
