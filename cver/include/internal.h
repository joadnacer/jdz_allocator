#pragma once

#include "types.h"
#include "utils.h"
#include "static_config.h"

#include <assert.h>

/* -----------------------------------------------------------
  arena.c
----------------------------------------------------------- */
void _jdz_arena_init(arena_t *arena);

void _jdz_arena_deinit(arena_t *arena);

void* _jdz_arena_allocate_to_span(arena_t *arena, size_class_t size_class);

void* _jdz_arena_allocate_one_span(arena_t *arena, size_class_t size_class);

void* _jdz_arena_allocate_to_large_span(arena_t *arena, size_t span_count);

/* -----------------------------------------------------------
  deferred_span_list.c
----------------------------------------------------------- */

void _jdz_deferred_span_list_write(deferred_span_list_t *span_list, span_t *span);

span_t* _jdz_deferred_span_list_get_and_remove_list(deferred_span_list_t *span_list);

/* -----------------------------------------------------------
  mpsc_large_cache.c
----------------------------------------------------------- */

void _jdz_large_cache_init(mpsc_large_cache_t *cache);

int _jdz_large_cache_try_write(mpsc_large_cache_t *cache, span_t *span);

span_t* _jdz_large_cache_try_read(mpsc_large_cache_t *cache);

/* -----------------------------------------------------------
  span_cache.c
----------------------------------------------------------- */

int _jdz_cache_try_write(span_cache_t *cache, span_t *span);

span_t* _jdz_cache_try_read(span_cache_t *cache);

/* -----------------------------------------------------------
  span_list.c
----------------------------------------------------------- */

void _jdz_span_list_write(span_list_t *span_list, span_t *span);

void _jdz_span_list_write_linked(span_list_t *span_list, span_t* linked_spans);

span_t* _jdz_span_list_try_read(span_list_t *span_list);

span_t* _jdz_span_list_get_empty_spans(span_list_t *span_list);

void _jdz_span_list_remove_head(span_list_t *span_list);

/* -----------------------------------------------------------
  span.c
----------------------------------------------------------- */

void _jdz_span_push_free_list(span_t *span, void *block);

void _jdz_span_push_deferred_free_list(span_t *span, void *block);

void* _jdz_span_pop_free_list(span_t *span);

void* _jdz_span_allocate(span_t *span);

void* _jdz_span_allocate_from_fresh(span_t *span);

void* _jdz_span_allocate_from_large_span(span_t *span);

int _jdz_span_is_full(span_t *span);

int _jdz_span_is_empty(span_t *span);

void _jdz_span_initialise_fresh_span(span_t *span, arena_t *arena, size_class_t size_class);

void _jdz_span_initialise_fresh_large_span(span_t *span, arena_t *arena, size_t span_count);

span_t* _jdz_span_split_first_spans_return_remaining(span_t *span, size_t span_count);

#define _jdz_span_split_last_spans(a, b) _jdz_span_split_first_spans_return_remaining(a. a->span_count - b)

#define _jdz_span_split_first_span_return_remaining(a) _jdz_span_split_first_spans_return_remaining(a, 1)