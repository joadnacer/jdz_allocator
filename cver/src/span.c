#include "internal.h"

#include <pthread.h>

static void* _jdz_span_alloc_deferred_or_ptr(span_t *span);

static void* _jdz_span_alloc_from_alloc_ptr(span_t *span);

static int _jdz_span_free_deferred_list(span_t *span);

void _jdz_span_push_free_list(span_t *span, void *block) {
    *((void**)block) = span->free_list;
    span->free_list = block;

    span->block_count -= 1;
}

void _jdz_span_push_deferred_free_list(span_t *span, void *block) {
    pthread_rwlock_rdlock(&span->deferred_lock);

    while (1) {
        *((void**)block) = &span->deferred_free_list;

        if (atomic_compare_exchange_weak_explicit((_Atomic(void*)*) &span->deferred_free_list, (void**)block, block, memory_order_relaxed, memory_order_relaxed)) {
            atomic_fetch_add_explicit((_Atomic(uint16_t)*) &span->deferred_frees, 1, memory_order_relaxed);

            pthread_rwlock_unlock(&span->deferred_lock);

            return;
        }
    }
}

void* _jdz_span_pop_free_list(span_t *span) {
    span-> block_count += 1;

    void *block = span->free_list;
    span->free_list = *((void**)block);

    return block;
}

void* _jdz_span_allocate(span_t *span) {
    if (span->free_list != NULL) {
        return _jdz_span_pop_free_list(span);
    }

    return _jdz_span_alloc_deferred_or_ptr(span);
}

void* _jdz_span_allocate_from_fresh(span_t *span) {
    assert(_jdz_span_is_empty(span));

    void* res = (void*) span->alloc_ptr;
    span->alloc_ptr += span->class.block_size;
    span->block_count = 1;

    return res;
}


void* _jdz_span_allocate_from_large_span(span_t *span) {
    assert(_jdz_span_is_empty(span));

    span->block_count = 1;

    return (void*) span->alloc_ptr;
}

int _jdz_span_is_full(span_t *span) {
    return span->block_count == span->class.block_max && span->deferred_frees == 0;
}

int _jdz_span_is_empty(span_t *span) {
    return span->block_count - span->deferred_frees == 0;
}

void _jdz_span_initialise_fresh_span(span_t *span, arena_t *arena, size_class_t size_class) {
    span->arena = arena;
    span->initial_ptr = span->initial_ptr;
    span->alloc_ptr = ((size_t) span) + SPAN_HEADER_SIZE;
    span->alloc_size = span->alloc_size;
    span->class = size_class;
    span->free_list = NULL;
    span->deferred_free_list = NULL;
    pthread_rwlock_init(&span->deferred_lock, NULL);
    span->full = 0;
    span->next = NULL;
    span->prev = NULL;
    span->block_count = 0;
    span->deferred_frees = 0;
    span->span_count = 1;
    span->aligned_blocks = 0;
}

void _jdz_span_initialise_fresh_large_span(span_t *span, arena_t *arena, size_t span_count) {
    span->arena = arena;
    span->initial_ptr = span->initial_ptr;
    span->alloc_ptr = ((size_t) span) + SPAN_HEADER_SIZE;
    span->alloc_size = span->alloc_size;
    span->next = NULL;
    span->prev = NULL;
    span->block_count = 0;
    span->span_count = span_count;

    // span->class = undefined;
    // span->free_list = undefined;
    // span->deferred_free_list = undefined;
    // span->full = undefined;
    // span->deferred_lock = undefined;
    // span->deferred_frees = undefined;
    // span->aligned_blocks = undefined;
}

span_t*_jdz_span_instantiate_mapped_span(size_t span_alloc_ptr, size_t alloc_size, size_t map_count) {
    size_t after_pad = span_alloc_ptr & (MOD_SPAN_SIZE);
    size_t before_pad = after_pad != 0 ? SPAN_SIZE - after_pad : 0;
    size_t span_ptr = span_alloc_ptr + before_pad;

    span_t *span = (span_t*) span_ptr;
    span->initial_ptr = span_alloc_ptr;
    span->alloc_size = alloc_size;
    span->span_count = map_count;

    return span;
}

span_t* _jdz_span_split_first_spans_return_remaining(span_t *span, size_t span_count) {
    assert(span->span_count > span_count);

    span_t *remaining_span = (span_t*) ((size_t) span + SPAN_SIZE * span_count);

    remaining_span->span_count = span->span_count - span_count;
    remaining_span->alloc_size = span->alloc_size - ((size_t) remaining_span - span->initial_ptr);
    remaining_span->initial_ptr = (size_t) remaining_span;

    span->span_count = span_count;
    span->alloc_size = remaining_span->initial_ptr - span->initial_ptr;
    
    return remaining_span;
}

static void* _jdz_span_alloc_deferred_or_ptr(span_t *span) {
    if (_jdz_span_free_deferred_list(span)) {
        return _jdz_span_pop_free_list(span);
    }

    return _jdz_span_alloc_from_alloc_ptr(span);
}

static void* _jdz_span_alloc_from_alloc_ptr(span_t *span) {
    assert(span->alloc_ptr <= (size_t) span + SPAN_SIZE - span->class.block_size);

    span->block_count += 1;

    void *res = (void*) span->alloc_ptr;
    span->alloc_ptr += span->class.block_size;

    return res;
}

static int _jdz_span_free_deferred_list(span_t *span) {
    assert(span->free_list == NULL);

    if (span->deferred_free_list == NULL) {
        return 0;
    }

    pthread_rwlock_wrlock(&span->deferred_lock);

    span->free_list = span->deferred_free_list;
    span->block_count -= span->deferred_frees;
    span->deferred_free_list = NULL;
    span->deferred_frees = 0;

    pthread_rwlock_unlock(&span->deferred_lock);

    return 1;
}