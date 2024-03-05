#include "test_helper.h"
#include "internal.h"
#include "span_cache.c"

#include <stdlib.h>

int main(void) {
    TEST("Simple Write/Read") {
        span_cache_t cache;

        span_t *span = malloc(SPAN_SIZE);
        span->span_count = 1;

        _jdz_cache_try_write(&cache, span);

        span_t *read_one = _jdz_cache_try_read(&cache);
        span_t *read_two =  _jdz_cache_try_read(&cache);

        result &= read_one == span;
        result &= read_two == NULL;

        free(span);
    }

    TEST("Span Count Two Write/Read") {
        span_cache_t cache;

        span_t *span = malloc(SPAN_SIZE * 2);
        span->span_count = 2;

        _jdz_cache_try_write(&cache, span);

        span_t *read_one = _jdz_cache_try_read(&cache);
        span_t *read_two = _jdz_cache_try_read(&cache);
        span_t *read_three = _jdz_cache_try_read(&cache);

        result &= read_one == span;
        result &= read_two == (span_t *) (((char *) span) + SPAN_SIZE);
        result &= read_three == NULL;

        result &= read_one->span_count == 1;
        result &= read_two->span_count == 1;

        free(span);
    }

    TEST("Write to full") {
        span_cache_t cache;

        for (int i = 0; i < CACHE_SIZE; i++) {
            span_t span;

            span.span_count = 1;

            result &= _jdz_cache_try_write(&cache, &span);
        };

        span_t last_span;

        result &= (_jdz_cache_try_write(&cache, &last_span) == 0);
    }

    return print_test_summary();
}