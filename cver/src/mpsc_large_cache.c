#include "internal.h"

#define BUFFER_MASK (LARGE_CACHE_SIZE - 1)

#define jdz_cas_relaxed(x, y, z) atomic_compare_exchange_weak_explicit(x, y, z, memory_order_relaxed, memory_order_relaxed)

// Array based bounded multiple producer single consumer queue
// This is a modification of Dmitry Vyukov's https://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue
void _jdz_large_cache_init(mpsc_large_cache_t *cache) {
    for (int i = 0; i < LARGE_CACHE_SIZE; i++) {
        cache->buffer[i].seq = i;
    }

    cache->enqueue_pos = 0;
    cache->dequeue_pos = 0;
}

int _jdz_large_cache_try_write(mpsc_large_cache_t *cache, span_t *span) {
    size_t pos = atomic_load_explicit(&cache->enqueue_pos, memory_order_relaxed);
    cell_t *cell = NULL;

    while (1) {
        cell = &cache->buffer[pos & BUFFER_MASK];
        size_t seq = atomic_load_explicit(&cell->seq, memory_order_acquire);
        intptr_t diff = seq - pos;

        if (diff == 0 && jdz_cas_relaxed(&cache->enqueue_pos, &pos, pos + 1)) {
            break;
        }
        else if (diff < 0) {
            return 0;
        }
        else {
            pos = atomic_load_explicit(&cache->enqueue_pos, memory_order_relaxed);
        }
    }

    cell->span = span;
    atomic_store_explicit(&cell->seq, pos + 1, memory_order_release);

    return 1;
}

span_t* _jdz_large_cache_try_read(mpsc_large_cache_t *cache) {
    cell_t *cell = &cache->buffer[cache->dequeue_pos & BUFFER_MASK];
    size_t seq = atomic_load_explicit(&cell->seq, memory_order_acquire);
    size_t diff = seq - (cache->dequeue_pos + 1);

    if (diff == 0) {
        cache->dequeue_pos += 1;
    }
    else {
        return NULL;
    }

    span_t *span = cell->span;
    atomic_store_explicit(&cell->seq, cache->dequeue_pos + BUFFER_MASK, memory_order_release);

    return span;
}