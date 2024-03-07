#include "jdzmalloc.h"
#include "internal.h"

/* -----------------------------------------------------------
  Size Classes
----------------------------------------------------------- */
static size_class_t small_size_classes[SMALL_CLASS_COUNT];
static size_class_t medium_size_classes[MEDIUM_CLASS_COUNT];

static size_class_t span_class = {
    .block_size = SPAN_EFFECTIVE_SIZE,
    .block_max = 1,
    .class_idx = SMALL_CLASS_COUNT + MEDIUM_CLASS_COUNT
};

static void _jdz_merge_size_classes(size_class_t *size_classes, size_t class_count) {
    for (int i = class_count - 1; i > 0; i--) {
        if (size_classes[i].block_max == size_classes[i - 1].block_max) {
            // need to maintain power of 2 classes for alignment
            if (IS_POWER_OF_TWO(size_classes[i].block_size)) {
                continue;
            }

            size_classes[i - 1].block_size = size_classes[i].block_size;
            size_classes[i - 1].class_idx = size_classes[i].class_idx;
        }
    }
}

static void _jdz_init_small_size_classes() {
    for (int i = 0; i < SMALL_CLASS_COUNT; i++) {
        small_size_classes[i].block_size = (i + 1) * SMALL_GRANULARITY;
        small_size_classes[i].block_max = SPAN_EFFECTIVE_SIZE / small_size_classes[i].block_size;
        small_size_classes[i].class_idx = i;
    }

    _jdz_merge_size_classes(small_size_classes, SMALL_CLASS_COUNT);

    assert(small_size_classes[0].block_size == SMALL_GRANULARITY);
    assert(small_size_classes[SMALL_CLASS_COUNT - 1].block_size == SMALL_MAX);
}

static void _jdz_init_medium_size_classes() {
    for (int i = 0; i < MEDIUM_CLASS_COUNT; i++) {
        medium_size_classes[i].block_size = SMALL_MAX + (i + 1) * MEDIUM_GRANULARITY;
        medium_size_classes[i].block_max = SPAN_EFFECTIVE_SIZE / medium_size_classes[i].block_size;
        medium_size_classes[i].class_idx = SMALL_CLASS_COUNT + i;
    }

    _jdz_merge_size_classes(medium_size_classes, MEDIUM_CLASS_COUNT);

    assert(medium_size_classes[0].block_size == SMALL_MAX + MEDIUM_GRANULARITY);
    assert(medium_size_classes[MEDIUM_CLASS_COUNT - 1].block_size == MEDIUM_MAX);
    assert(medium_size_classes[MEDIUM_CLASS_COUNT - 1].block_max > 1);
}

static inline size_class_t _jdzmalloc_get_small_size_class(size_t size) {
    assert(size <= SMALL_MAX);

    return small_size_classes[(size - 1) >> SMALL_GRANULARITY_SHIFT];
}

static inline size_class_t _jdzmalloc_get_medium_size_class(size_t size) {
    assert(size > SMALL_MAX && size <= MEDIUM_MAX);

    return medium_size_classes[(size - SMALL_MAX - 1) >> MEDIUM_GRANULARITY_SHIFT];
}

/* -----------------------------------------------------------
  Allocator
----------------------------------------------------------- */
# define TLS_MODEL __attribute__((tls_model("initial-exec")))

static arena_t base_arena;
static int base_arena_used;

static _Thread_local arena_t *thread_arena TLS_MODEL;

int jdzmalloc_init(void) {
    _jdz_init_small_size_classes();
    _jdz_init_medium_size_classes();

    _jdz_arena_init(&base_arena);
    jdzmalloc_thread_init();
  // TODO
}

void jdzmalloc_deinit(void) {
    // TODO
}

static arena_t* _jdzmalloc_arena_init() {
    // should be atomic if doing this
    if (!base_arena_used) {
        base_arena_used = 1;

        return &base_arena;
    }

    // TODO: allocate new
}

void jdzmalloc_thread_init(void) {
    thread_arena = _jdzmalloc_arena_init();
}

void* jdzmalloc(size_t size) {
    if (size <= SMALL_MAX) {
        return _jdz_arena_allocate_to_span(thread_arena, _jdzmalloc_get_small_size_class(size));
    }
    else if (size <= MEDIUM_MAX) {
        return _jdz_arena_allocate_to_span(thread_arena, _jdzmalloc_get_medium_size_class(size));
    }
    else if (size <= SPAN_MAX) {
        return _jdz_arena_allocate_one_span(thread_arena, span_class);
    }
    else if (size <= LARGE_MAX) {
        return _jdz_arena_allocate_to_large_span(thread_arena, size);
    }
    else {
        return _jdz_arena_allocate_direct(thread_arena, size);
    }
}

void jdzfree(void* ptr) {
    span_t *span = (span_t*) ((size_t) ptr & SPAN_UPPER_MASK);

    // TODO: why is this needed?
    if (span == NULL || span->span_count == 0) {
        return;
    }

    if (span->span_count == 1 && span->class.block_size <= MEDIUM_MAX) {
        _jdz_arena_free_small_or_medium(span->arena, thread_arena, span, ptr);
    }
    else if (span->span_count == 1) {
        // TODO: NOT THREADSAFE
        _jdz_arena_cache_span_or_free(span->arena, span);
    }
    else if (span->span_count <= LARGE_CLASS_COUNT) {
        _jdz_arena_cache_large_span_or_free(span->arena, span);
    }
    else {
        _jdz_arena_free_direct(span->arena, span);
    }
}