#pragma once

#include "internal.h"
/* -----------------------------------------------------------
  Small or Medium Allocations
----------------------------------------------------------- */

static void* _jdz_arena_allocate_generic(arena_t *arena, size_class_t size_class);

static void* _jdz_arena_allocate_from_span_list(arena_t *arena, size_class_t size_class);

static void* _jdz_arena_allocate_from_deferred_partial_spans(arena_t *arena, size_class_t size_class);

static void* _jdz_arena_allocate_from_cache_or_new(arena_t *arena, size_class_t size_class);

static span_t* _jdz_arena_get_span_from_cache_or_new(arena_t *arena);

static span_t* _jdz_arena_get_empty_spans_from_lists(arena_t *arena);

#ifdef SPLIT_LARGE_SPANS_TO_ONE
static span_t* _jdz_arena_get_spans_from_large_cache(arena_t *arena);
#endif

static void _jdz_arena_cache_spans_from_large_span(arena_t *arena, span_t *span);

/* -----------------------------------------------------------
  Large Span Allocations
----------------------------------------------------------- */

static span_t* _jdz_arena_get_large_span(arena_t *arena, size_t span_count);

static span_t* _jdz_arena_get_large_span_from_caches(arena_t *arena, size_t span_count, size_t max_span_count);

static span_t* _jdz_arena_get_from_large_cache(arena_t *arena, size_t span_count, size_t max_span_count);

#ifdef SPLIT_LARGE_SPANS_TO_LARGE
static span_t* _jdz_arena_split_larger_cached_span(arena_t *arena, size_t desired_count, size_t from_count);
#endif

static void* _jdz_arena_allocate_from_new_large_span(arena_t *arena, size_t span_count);

/* -----------------------------------------------------------
  Span Mapping
----------------------------------------------------------- */

static span_t* _jdz_arena_map_spans(arena_t *arena, size_t span_count, map_mode_t map_mode);

static span_t * _jdz_arena_map_multiple_spans(arena_t *arena, span_t *span);
