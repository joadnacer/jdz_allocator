
#include "test_helper.h"
#include "internal.h"
#include "mpsc_large_cache.c"

int main(void) {
    TEST("Simple Write/Read") {
        mpsc_large_cache_t cache;
        _jdz_large_cache_init(&cache);
        
        span_t span;

        _jdz_large_cache_try_write(&cache, &span);

        span_t *read_one = _jdz_large_cache_try_read(&cache);
        span_t *read_two = _jdz_large_cache_try_read(&cache);

        result &= read_one == &span;
        result &= read_two == NULL;
    }

    TEST("Write to full") {
        mpsc_large_cache_t cache;
        _jdz_large_cache_init(&cache);

        for (int i = 0; i < LARGE_CACHE_SIZE; i++) {
            span_t span;

            result &= _jdz_large_cache_try_write(&cache, &span);
        }

        span_t last_span;
        result &= (_jdz_large_cache_try_write(&cache, &last_span) == 0);
    }

    return print_test_summary();
}