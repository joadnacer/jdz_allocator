#include "internal.h"
#include "arena_static.h"

#include <sys/mman.h>

#ifndef MAP_UNINITIALIZED
#  define MAP_UNINITIALIZED 0
#endif

#define MAX(a,b) \
({ __typeof__ (a) _a = (a); \
    __typeof__ (b) _b = (b); \
    _a > _b ? _a : _b; })

#define MIN(a,b) \
({ __typeof__ (a) _a = (a); \
    __typeof__ (b) _b = (b); \
    _a < _b ? _a : _b; })

/* -----------------------------------------------------------
  Declarations
----------------------------------------------------------- */

/* -----------------------------------------------------------
  Initialisation
----------------------------------------------------------- */
void _jdz_arena_init(arena_t *arena) {
    _jdz_large_cache_init(&arena->large_cache);
}

void _jdz_arena_deinit(arena_t *arena) {
    // TODO
}

/* -----------------------------------------------------------
  Small or Medium Allocations
----------------------------------------------------------- */
void* _jdz_arena_allocate_to_span(arena_t *arena, size_class_t size_class) {
    span_t *span = _jdz_span_list_try_read(&arena->spans[size_class.class_idx]);
    if (span != NULL && span->free_list != NULL) {
        return _jdz_span_pop_free_list(span);
    }

    return _jdz_arena_allocate_generic(arena, size_class);
}

static void* _jdz_arena_allocate_generic(arena_t *arena, size_class_t size_class) {
    void *alloc;

    if (alloc = _jdz_arena_allocate_from_span_list(arena, size_class)) {
        return alloc;
    }

    if (alloc = _jdz_arena_allocate_from_deferred_partial_spans(arena, size_class)) {
        return alloc;
    }

    if (alloc = _jdz_arena_allocate_from_cache_or_new(arena, size_class)) {
        return alloc;
    }
}

static void* _jdz_arena_allocate_from_span_list(arena_t *arena, size_class_t size_class) {
    span_t *span;

    while (span = _jdz_span_list_try_read(&arena->spans[size_class.class_idx])) {
        if (_jdz_span_is_full(span)) {
            atomic_store_explicit(&span->full, 1, memory_order_relaxed);

            _jdz_span_list_remove_head(&arena->spans[size_class.class_idx]);
        }
        else {
            return _jdz_span_allocate(span);
        }
    }
}

static void* _jdz_arena_allocate_from_deferred_partial_spans(arena_t *arena, size_class_t size_class) {
    span_t *partial_span = _jdz_deferred_span_list_get_and_remove_list(&arena->deferred_partial_spans[size_class.class_idx]);

    if (partial_span != NULL) {
        _jdz_span_list_write_linked(&arena->spans[size_class.class_idx], partial_span);

        return _jdz_span_allocate(partial_span);
    }

    return NULL;
}

static void* _jdz_arena_allocate_from_cache_or_new(arena_t *arena, size_class_t size_class) {
    span_t *span = _jdz_arena_get_span_from_cache_or_new(arena);

    if (span != NULL) {
        _jdz_span_initialise_fresh_span(span, arena, size_class);

        _jdz_span_list_write(&arena->spans[size_class.class_idx], span);

        return _jdz_span_allocate_from_fresh(span);
    }

    return NULL;
}

static span_t* _jdz_arena_get_span_from_cache_or_new(arena_t *arena) {
    span_t *span;

    if (span = _jdz_cache_try_read(&arena->cache)) {
        return span;
    }

    if (span = _jdz_arena_get_empty_spans_from_lists(arena)) {
        return span;
    }

    #ifdef SPLIT_LARGE_SPANS_TO_ONE
    if (span = _jdz_arena_get_spans_from_large_cache(arena)) {
        return span;
    }
    #endif

    return _jdz_arena_map_spans(arena, SPAN_ALLOC_COUNT, MULTIPLE);
}

static span_t* _jdz_arena_get_empty_spans_from_lists(arena_t *arena) {
    span_t *ret_span;

    for (int i = 0; i < SIZE_CLASS_COUNT; i++) {
        span_t *empty_spans = _jdz_span_list_get_empty_spans(&arena->spans[i]);

        if (empty_spans != NULL) {
            if (ret_span != NULL) {
                _jdz_arena_cache_span_or_free(arena, ret_span);
            }

            span_t *next;
            while (next = empty_spans->next) {
                ret_span = next;

                _jdz_arena_cache_span_or_free(arena, empty_spans);

                empty_spans = next;
            }
        }
    }

    return ret_span;
}

#ifdef SPLIT_LARGE_SPANS_TO_ONE
static span_t* _jdz_arena_get_spans_from_large_cache(arena_t *arena) {
    size_t span_count = LARGE_CLASS_COUNT;

    for (; span_count >= 2; span_count--) {
        span_t *large_span = _jdz_large_cache_try_read(&arena->large_cache[span_count - 2]);

        if (large_span != NULL) {
            _jdz_arena_cache_spans_from_large_span(arena, large_span);

            return large_span;
        }
    }

    return NULL;
}
#endif

static void _jdz_arena_cache_spans_from_large_span(arena_t *arena, span_t *span) {
    span_t *to_cache = _jdz_span_split_first_span_return_remaining(span);

    int res = _jdz_cache_try_write(&arena->cache, to_cache);

    assert(res);
}

/* -----------------------------------------------------------
  Large Span Allocations
----------------------------------------------------------- */

void* _jdz_arena_allocate_one_span(arena_t *arena, size_class_t size_class) {
    span_t *span = _jdz_arena_get_span_from_cache_or_new(arena);

    if (span != NULL) {
        _jdz_span_initialise_fresh_span(span, arena, size_class);

        return _jdz_span_allocate_from_fresh(span);
    }

    return NULL;
}

void* _jdz_arena_allocate_to_large_span(arena_t *arena, size_t span_count) {
    span_t *span = _jdz_arena_get_large_span(arena, span_count);

    if (span != NULL) {
        _jdz_span_initialise_fresh_large_span(arena, span, span->span_count);

        return _jdz_span_allocate_from_large_span(span);
    }

    return _jdz_arena_allocate_from_new_large_span(arena, span_count);
}

static span_t* _jdz_arena_get_large_span(arena_t *arena, size_t span_count) {
    size_t span_overhead = (size_t) span_count * LARGE_SPAN_OVERHEAD_MUL;
    size_t max_span_count = MIN(LARGE_CLASS_COUNT, span_count + span_overhead);

    return _jdz_arena_get_large_span_from_caches(arena, span_count, max_span_count);
}

static span_t* _jdz_arena_get_large_span_from_caches(arena_t *arena, size_t span_count, size_t max_span_count) {
    span_t *span;

    if (span = _jdz_arena_get_from_large_cache(arena, span_count, max_span_count)) {
        return span;
    }

    #ifdef SPLIT_LARGE_SPANS_TO_LARGE
    if (span = _jdz_arena_split_larger_cached_span(arena, span_count, max_span_count)) {
        return span;
    }
    #endif

    return NULL;
}

static span_t* _jdz_arena_get_from_large_cache(arena_t *arena, size_t desired_count, size_t max_span_count) {
    for (size_t count = desired_count; count < max_span_count + 1; count++) {
        span_t *cached = _jdz_large_cache_try_read(&arena->large_cache[count - 2]);

        if (cached != NULL) {
            assert(cached->span_count == count);

            return cached;
        }
    }
}

#ifdef SPLIT_LARGE_SPANS_TO_LARGE
static span_t* _jdz_arena_split_larger_cached_span(arena_t *arena, size_t desired_count, size_t from_count) {
    for (size_t count = from_count; count < LARGE_CLASS_COUNT + 1; count++) {
        span_t *cached = _jdz_large_cache_try_read(&arena->large_cache[count - 2]);

        if (cached != NULL) {
            assert(cached->span_count == count);

            span_t *remaining = _jdz_span_split_first_spans_return_remaining(cached, desired_count);

            if (remaining->span_count > 1) {
                _jdz_arena_cache_large_span_or_free(arena, remaining, RECYCLE_LARGE_SPANS);
            }
            else {
                _jdz_arena_cache_span_or_free(arena, remaining);
            }

            return cached;
        }
    }

    return NULL;
}
#endif

static void* _jdz_arena_allocate_from_new_large_span(arena_t *arena, size_t span_count) {
    span_t *span = _jdz_arena_map_spans(arena, span_count, LARGE);

    if (span != NULL) {
        _jdz_span_initialise_fresh_large_span(span, arena, span_count);

        return _jdz_span_allocate_from_large_span(span);
    }

    return NULL;
}

/* -----------------------------------------------------------
  Span Mapping
----------------------------------------------------------- */

static inline size_t _jdz_arena_get_map_count(size_t desired_span_count) {
    return max(PAGE_SIZE / SPAN_SIZE, desired_span_count);
}

static span_t* _jdz_arena_map_spans(arena_t *arena, size_t span_count, map_mode_t map_mode) {
    size_t map_count = _jdz_arena_get_map_count(span_count);

    // need at least 1 extra span for padding
    if (map_count == span_count) {
        map_count += 1;
    }

    uintptr_t alloc_size = map_count * SPAN_SIZE;

    void* span_alloc = mmap(NULL,
                            alloc_size,
                            PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS | MAP_UNINITIALIZED,
                            -1,
                            0);
    
    uintptr_t span_alloc_ptr = (uintptr_t) span_alloc;

    // not aligned, can't use padding
    if ((span_alloc_ptr & MOD_SPAN_SIZE) != 0) {
        map_count -= 1;
    }

    span_t *span = _jdz_arena_get_spans_cache_remaining(arena, span_alloc_ptr, alloc_size, map_count, span_count);

    switch (map_mode) {
        case MULTIPLE:
            return _jdz_arena_map_multiple_spans(arena, span);
        case LARGE:
            return span;
    }
}

static span_t * _jdz_arena_map_multiple_spans(arena_t *arena, span_t *span) {
    if (span->span_count > 1) {
        span_t *remaining = _jdz_span_split_first_span_return_remaining(span);

        int cached = _jdz_cache_try_write(&arena->cache, remaining);

        // should never be mapping if have spans in span cache
        assert(cached);
    }

    return span;
}
