#pragma once

#include "stdint.h"
#include "stddef.h"
#include "pthread.h"
#include "stdalign.h"
#include "stdatomic.h"

#define SPAN_SIZE (65536)
#define MOD_SPAN_SIZE (SPAN_SIZE - 1)

#define SPAN_HEADER_SIZE (512)
#define SPAN_EFFECTIVE_SIZE (SPAN_SIZE - SPAN_HEADER_SIZE)
#define SPAN_MAX (SPAN_EFFECTIVE_SIZE)

#define SPAN_ALIGNMENT (16)
#define SPAN_LOWER_MASK (SPAN_SIZE - 1)
#define SPAN_UPPER_MASK (~SPAN_LOWER_MASK)

#define SMALL_GRANULARITY (16)
#define SMALL_GRANULARITY_SHIFT (4)
#define SMALL_MAX (2048)
#define SMALL_CLASS_COUNT (SMALL_MAX / SMALL_GRANULARITY)

#define MEDIUM_GRANULARITY (256)
#define MEDIUM_GRANULARITY_SHIFT (8)
#define MEDIUM_MAX (SPAN_EFFECTIVE_SIZE / 2 - ((SPAN_EFFECTIVE_SIZE / 2) % MEDIUM_GRANULARITY))
#define MEDIUM_CLASS_COUNT ((MEDIUM_MAX - SMALL_MAX) / MEDIUM_GRANULARITY)

#define LARGE_CLASS_COUNT (64)
#define LARGE_MAX (LARGE_CLASS_COUNT * SPAN_SIZE - SPAN_HEADER_SIZE)

#define SIZE_CLASS_COUNT (SMALL_CLASS_COUNT + MEDIUM_CLASS_COUNT)

#define JDZ_CACHE_LINE (64)

#define jdz_cache_aligned alignas(JDZ_CACHE_LINE)

#define CACHE_SIZE (64)
#define LARGE_CACHE_SIZE (64)

typedef struct arena_t arena_t;
typedef struct span_t span_t;
typedef struct size_class_t size_class_t;
typedef struct span_cache_t span_cache_t;
typedef struct span_list_t span_list_t;
typedef struct deferred_span_list_t deferred_span_list_t;
typedef struct cell_t cell_t;
typedef struct mpsc_large_cache_t mpsc_large_cache_t;

struct size_class_t {
    uint32_t block_size;
    uint16_t block_max;
    uint16_t class_idx;
};

struct span_t {
    arena_t *arena;
    void *free_list;
    void *deferred_free_list;
    pthread_rwlock_t deferred_lock;
    size_class_t class;
    span_t *next;
    span_t *prev;
    size_t alloc_ptr;
    uint16_t block_count;
    uint16_t deferred_frees;
    size_t initial_ptr;
    size_t alloc_size;
    size_t span_count;
    int full;
    int aligned_blocks;
};

struct span_cache_t {
    size_t count;
    span_t *buffer[CACHE_SIZE];
};

struct span_list_t {
    span_t *head;
    span_t *tail;
};

struct deferred_span_list_t {
    span_t *head;
};

struct cell_t {
    atomic_size_t seq;
    span_t *span;
};

struct mpsc_large_cache_t {
    jdz_cache_aligned atomic_size_t enqueue_pos;
    jdz_cache_aligned size_t dequeue_pos;
    cell_t buffer[LARGE_CACHE_SIZE];
};

struct arena_t {
    span_list_t spans[SIZE_CLASS_COUNT];
    deferred_span_list_t deferred_partial_spans[SIZE_CLASS_COUNT];
    #if REPORT_LEAKS
    size_t span_count;
    #endif
    span_cache_t cache;
    mpsc_large_cache_t large_cache[LARGE_CLASS_COUNT];
    arena_t *next;
};

typedef enum map_mode_t {
    LARGE,
    MULTIPLE,
} map_mode_t;