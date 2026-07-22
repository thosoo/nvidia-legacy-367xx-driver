/*
 * Abstract state model for the NVIDIA 367 core workqueue backport.
 *
 * This userspace model is intentionally small and deterministic. It validates
 * state-machine invariants and selected interleavings, but it is not proof of
 * kernel-runtime correctness or proprietary RM callback behavior.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

typedef enum {
    NV_WQ_UNINITIALIZED,
    NV_WQ_INITIALIZING,
    NV_WQ_RUNNING,
    NV_WQ_DRAINING,
    NV_WQ_STOPPING,
    NV_WQ_STOPPED
} state_t;

typedef struct {
    state_t state;
    unsigned long long generation;
    unsigned long long stop_generation;
    int stop_calls;
    int worker_present;
    unsigned long long next_sequence;
    unsigned long long completed_sequence;
    int queued_items;
    int worker_running;
    int callback_returned;
    int cleanup_done;
    int dynamic_accepted;
} queue_t;

typedef struct {
    int queued;
    int running;
    int requeueable;
    unsigned long long queued_sequence;
    int accepted_count;
} task_t;

static unsigned int rng = 0x367134u;

static void fail_seed(const char *msg)
{
    fprintf(stderr, "state-model failure seed=0x%x: %s\n", rng, msg);
    abort();
}

static unsigned int rnd(void)
{
    rng = rng * 1103515245u + 12345u;
    return rng;
}

static void invariants(const queue_t *q, const task_t *dyn)
{
    if (q->completed_sequence > q->next_sequence)
        fail_seed("completed_sequence advanced past next_sequence");
    if (q->state == NV_WQ_STOPPING && q->queued_items != 0)
        fail_seed("STOPPING with queued work");
    if (q->state == NV_WQ_STOPPED && (q->worker_present || q->queued_items || q->worker_running))
        fail_seed("STOPPED with worker/queued/running work");
    if (dyn->accepted_count > 1)
        fail_seed("dynamic one-shot accepted more than once");
    if (q->worker_running && q->completed_sequence == q->next_sequence)
        fail_seed("completion published while callback still running");
}

static int can_schedule(task_t *task, state_t state, int thread)
{
    return thread &&
           (state == NV_WQ_RUNNING || state == NV_WQ_DRAINING) &&
           !task->queued &&
           (task->requeueable || task->queued_sequence == 0);
}

static int schedule_task(queue_t *q, task_t *task)
{
    if (!can_schedule(task, q->state, q->worker_present))
        return 0;
    task->queued_sequence = ++q->next_sequence;
    task->queued = 1;
    task->accepted_count++;
    q->queued_items++;
    return 1;
}

static int begin_shutdown(queue_t *q, int self, unsigned long long *observed)
{
    if (self)
        return -11;
    if (q->state == NV_WQ_UNINITIALIZED || q->state == NV_WQ_STOPPED) {
        q->state = NV_WQ_STOPPED;
        return 0;
    }
    if (q->state == NV_WQ_INITIALIZING ||
        q->state == NV_WQ_DRAINING ||
        q->state == NV_WQ_STOPPING) {
        *observed = q->generation;
        return 1;
    }
    q->state = NV_WQ_DRAINING;
    q->stop_generation = q->generation;
    return 2;
}

static int waiter_done(queue_t *q, unsigned long long observed)
{
    return q->generation != observed;
}

static void worker_dequeue(queue_t *q, task_t *task)
{
    assert(q->queued_items > 0);
    assert(task->queued);
    q->queued_items--;
    q->worker_running = 1;
    q->callback_returned = 0;
    q->cleanup_done = 0;
    task->queued = 0;
    task->running = 1;
}

static void callback_return(queue_t *q)
{
    assert(q->worker_running);
    q->callback_returned = 1;
}

static void cleanup_complete(queue_t *q)
{
    assert(q->callback_returned);
    q->cleanup_done = 1;
}

static void publish_completion(queue_t *q, task_t *task)
{
    assert(q->worker_running);
    assert(q->callback_returned);
    assert(q->cleanup_done);
    q->worker_running = 0;
    task->running = 0;
    q->completed_sequence++;
}

static int stable_quiescent(queue_t *q)
{
    return q->queued_items == 0 &&
           q->completed_sequence == q->next_sequence;
}

static int owner_try_stop(queue_t *q)
{
    assert(q->state == NV_WQ_DRAINING);
    if (!stable_quiescent(q))
        return 0;
    q->state = NV_WQ_STOPPING;
    q->stop_calls++;
    q->worker_present = 0;
    q->state = NV_WQ_STOPPED;
    q->generation++;
    return 1;
}

static int begin_init(queue_t *q)
{
    if (q->state == NV_WQ_INITIALIZING || q->state == NV_WQ_RUNNING ||
        q->state == NV_WQ_DRAINING || q->state == NV_WQ_STOPPING)
        return -1;
    q->state = NV_WQ_INITIALIZING;
    return 0;
}

static void finish_init(queue_t *q, int ok)
{
    q->state = ok ? NV_WQ_RUNNING : NV_WQ_STOPPED;
    q->worker_present = ok;
    if (!ok)
        q->generation++;
}

static void deterministic_cases(void)
{
    task_t dyn = {0,0,0,0,0};
    task_t stat = {0,0,1,0,0};
    queue_t q = { NV_WQ_RUNNING, 7, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 };
    unsigned long long seen = 0;

    assert(schedule_task(&q, &dyn));
    assert(!schedule_task(&q, &dyn));
    worker_dequeue(&q, &dyn);
    assert(!schedule_task(&q, &dyn));
    callback_return(&q);
    cleanup_complete(&q);
    publish_completion(&q, &dyn);
    assert(!schedule_task(&q, &dyn));
    invariants(&q, &dyn);

    assert(schedule_task(&q, &stat));
    assert(!schedule_task(&q, &stat));
    worker_dequeue(&q, &stat);
    assert(schedule_task(&q, &stat));
    assert(!schedule_task(&q, &stat));
    callback_return(&q);
    cleanup_complete(&q);
    publish_completion(&q, &stat);
    worker_dequeue(&q, &stat);
    callback_return(&q);
    cleanup_complete(&q);
    publish_completion(&q, &stat);
    invariants(&q, &dyn);

    assert(begin_shutdown(&q, 0, &seen) == 2 && q.state == NV_WQ_DRAINING);
    assert(begin_shutdown(&q, 0, &seen) == 1 && seen == 7);
    assert(schedule_task(&q, &stat));
    worker_dequeue(&q, &stat);
    assert(q.queued_items == 0 && !stable_quiescent(&q));
    assert(!owner_try_stop(&q));
    assert(schedule_task(&q, &stat));
    callback_return(&q);
    cleanup_complete(&q);
    publish_completion(&q, &stat);
    assert(!stable_quiescent(&q));
    worker_dequeue(&q, &stat);
    callback_return(&q);
    cleanup_complete(&q);
    publish_completion(&q, &stat);
    assert(stable_quiescent(&q));
    assert(owner_try_stop(&q));
    assert(q.stop_calls == 1 && q.generation == 8 && waiter_done(&q, seen));
    assert(!schedule_task(&q, &stat));
    invariants(&q, &dyn);

    assert(begin_shutdown(&q, 0, &seen) == 0 && q.stop_calls == 1);
    q.state = NV_WQ_RUNNING;
    q.worker_present = 1;
    assert(begin_shutdown(&q, 1, &seen) == -11 && q.state == NV_WQ_RUNNING);

    q.state = NV_WQ_INITIALIZING;
    q.worker_present = 0;
    q.generation = 11;
    assert(begin_shutdown(&q, 0, &seen) == 1 && seen == 11);
    finish_init(&q, 1);
    assert(q.state == NV_WQ_RUNNING && q.generation == 11);

    q.state = NV_WQ_STOPPED;
    q.worker_present = 0;
    assert(begin_init(&q) == 0 && begin_init(&q) == -1);
    finish_init(&q, 0);
    assert(q.state == NV_WQ_STOPPED && q.generation == 12);
    assert(begin_init(&q) == 0);
    finish_init(&q, 1);
    assert(q.state == NV_WQ_RUNNING && q.generation == 12);

    q.state = NV_WQ_DRAINING;
    q.generation = 20;
    assert(begin_shutdown(&q, 0, &seen) == 1);
    q.state = NV_WQ_STOPPED;
    q.worker_present = 0;
    q.generation = 21;
    assert(waiter_done(&q, seen));
    assert(begin_init(&q) == 0);
    finish_init(&q, 1);
}

static void stress_cases(void)
{
    int i;
    for (i = 0; i < 2000; i++) {
        queue_t q = { NV_WQ_RUNNING, i + 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 };
        task_t stat = {0,0,1,0,0};
        task_t dyn = {0,0,0,0,0};
        unsigned long long seen = 0;
        int owner = 0;
        int step;

        for (step = 0; step < 32; step++) {
            switch (rnd() % 8) {
            case 0:
                (void)schedule_task(&q, &stat);
                break;
            case 1:
                (void)schedule_task(&q, &dyn);
                break;
            case 2:
                if (!q.worker_running && q.queued_items > 0)
                    worker_dequeue(&q, stat.queued ? &stat : &dyn);
                break;
            case 3:
                if (q.worker_running && !q.callback_returned)
                    callback_return(&q);
                break;
            case 4:
                if (q.callback_returned && !q.cleanup_done)
                    cleanup_complete(&q);
                break;
            case 5:
                if (q.worker_running && q.callback_returned && q.cleanup_done)
                    publish_completion(&q, stat.running ? &stat : &dyn);
                break;
            case 6:
                if (!owner)
                    owner = begin_shutdown(&q, 0, &seen) == 2;
                else
                    assert(begin_shutdown(&q, 0, &seen) == 1 || q.state == NV_WQ_STOPPED);
                break;
            case 7:
                if (owner && q.state == NV_WQ_DRAINING)
                    (void)owner_try_stop(&q);
                break;
            }
            invariants(&q, &dyn);
        }
    }
}

int main(void)
{
    deterministic_cases();
    stress_cases();
    return 0;
}
