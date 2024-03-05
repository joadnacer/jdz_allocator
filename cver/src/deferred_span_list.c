#include "internal.h"

void _jdz_deferred_span_list_write(deferred_span_list_t *span_list, span_t *span) {
    while (1) {
        span->next = span_list->head;

        if (atomic_compare_exchange_weak_explicit(&span_list->head, &span->next, span, memory_order_relaxed, memory_order_relaxed)) {
            return;
        }
    }
}

span_t* _jdz_deferred_span_list_get_and_remove_list(deferred_span_list_t *span_list) {
    return atomic_exchange_explicit(&span_list->head, NULL, memory_order_relaxed);
}