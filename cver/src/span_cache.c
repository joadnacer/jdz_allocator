#include "internal.h"

int _jdz_cache_try_write(span_cache_t *cache, span_t *span) {
    if (cache->count == CACHE_SIZE) {
        return 0;
    }

    cache->buffer[cache->count] = span;
    cache->count += 1;

    return 1;
}

span_t* _jdz_cache_try_read(span_cache_t *cache) {
    if (cache->count == 0) {
        return NULL;
    }

    cache->count -= 1;

    span_t *span = cache->buffer[cache->count];

    if (span->span_count > 1) {
        span_t *split_spans = _jdz_span_split_first_span_return_remaining(span);

        _jdz_cache_try_write(cache, split_spans);
    }

    return span;
}