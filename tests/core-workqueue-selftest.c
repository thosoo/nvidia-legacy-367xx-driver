/*
 * Compile-only design sketch for an optional in-kernel NV_WORKQUEUE_SELFTEST.
 *
 * This is a userspace harness for the intended behavioral cases; released
 * packages do not define NV_WORKQUEUE_SELFTEST and do not compile or execute an
 * in-kernel selftest. The actual kernel integration is documented in
 * docs/testing/core-workqueue-selftest.md.
 */
#ifndef NV_WORKQUEUE_SELFTEST
#error "compile with -DNV_WORKQUEUE_SELFTEST to validate the selftest scaffold"
#endif
#include <assert.h>
#include <stdio.h>

typedef struct item item_t;
typedef void (*handler_t)(item_t *);

struct item {
    int queued;
    int running;
    int requeueable;
    int owned;
    int cleaned;
    int calls;
    handler_t handler;
};

typedef struct queue {
    int running;
    int stopping;
    int depth;
    unsigned long long next;
    unsigned long long done;
    int shutdown_owners;
} queue_t;

static int schedule(queue_t *q, item_t *item)
{
    if (!q->running || q->stopping || item->queued ||
        (!item->requeueable && item->calls != 0))
        return 0;
    item->queued = 1;
    q->depth++;
    q->next++;
    return 1;
}

static void execute_one(queue_t *q, item_t *item)
{
    assert(item->queued);
    item->queued = 0;
    item->running = 1;
    q->depth--;
    item->handler(item);
    item->running = 0;
    if (item->owned)
        item->cleaned++;
    q->done++;
}

static void noop(item_t *item) { item->calls++; }
static void self_requeue(item_t *item) { item->calls++; }

int main(void)
{
    queue_t q = {1, 0, 0, 0, 0, 0};
    item_t stat = {0, 0, 1, 0, 0, 0, noop};
    item_t dyn = {0, 0, 0, 1, 0, 0, noop};
    item_t self = {0, 0, 1, 0, 0, 0, self_requeue};

    assert(schedule(&q, &stat));
    assert(!schedule(&q, &stat));
    execute_one(&q, &stat);
    assert(schedule(&q, &stat));
    execute_one(&q, &stat);

    assert(schedule(&q, &dyn));
    assert(!schedule(&q, &dyn));
    execute_one(&q, &dyn);
    assert(dyn.cleaned == 1);
    assert(!schedule(&q, &dyn));

    assert(schedule(&q, &self));
    execute_one(&q, &self);
    assert(schedule(&q, &self));
    execute_one(&q, &self);

    q.shutdown_owners++;
    q.stopping = 1;
    assert(!schedule(&q, &stat));
    assert(q.shutdown_owners == 1);
    assert(q.depth == 0 && q.done == q.next);
    return 0;
}
