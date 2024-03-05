#include "internal.h"

static void _jdz_span_list_assert_not_in_list(span_t *span) {
    assert(span->next == NULL);
    assert(span->prev == NULL);
}

static void _jdz_span_list_reset_span(span_t *span) {
    span->next = NULL;
    span->prev = NULL;
}

static void _jdz_span_list_remove(span_list_t *span_list, span_t *span) {
    assert(span->prev != span->next);

    if (span->prev != NULL) {
        span->prev->next = span->next;
    }
    else {
        span_list->head = span->next;
    }

    if (span->next != NULL) {
        span->next->prev = span->prev;
    }
    else {
        span_list->tail = span->prev;
    }

    _jdz_span_list_reset_span(span);
}

static span_t* _jdz_span_list_remove_get_next(span_list_t *span_list, span_t *span) {
    span_t *next = span->next;

    _jdz_span_list_remove(span_list, span);

    return next;
}

void _jdz_span_list_write(span_list_t *span_list, span_t *span) {
    _jdz_span_list_assert_not_in_list(span);

    if (span_list->tail != NULL) {
        span_t *tail = span_list->tail;
        tail->next = span;

        span_list->tail = span;
        span->prev = tail;
    }
    else {
        span_list->head = span;
        span_list->tail = span;
    }
}

void _jdz_span_list_write_linked(span_list_t *span_list, span_t* linked_spans) {
    if (span_list->tail != NULL) {
        span_list->tail->next = linked_spans;

        linked_spans->prev = span_list->tail;
    }
    else {
        span_list->head = linked_spans;
    }

    span_t *span = linked_spans;

    while (span->next != NULL) {
        span->next->prev = span;
        
        span = span->next;
    }

    span_list->tail = span;
}

span_t* _jdz_span_list_try_read(span_list_t *span_list) {
    return span_list->head;
}

span_t* _jdz_span_list_get_empty_spans(span_list_t *span_list) {
    if (span_list->head == NULL) {
        return NULL;
    }

    span_t *empty_spans_head = NULL;
    span_t *empty_spans_cur = NULL;

    span_t *span = span_list->head;

    while (span != NULL) {
        assert(span != span->next);

        if (_jdz_span_is_empty(span)) {
            span_t *next = _jdz_span_list_remove_get_next(span_list, span);

            if (empty_spans_cur != NULL) {
                assert(empty_spans_cur != span);

                empty_spans_cur->next = span;
                span->prev = empty_spans_cur;
                empty_spans_cur = span;
            }
            else {
                empty_spans_head = span;
                empty_spans_cur = span;
            }

            span = next;
        }
        else {
            span = span->next;
        }
    }
}

void _jdz_span_list_remove_head(span_list_t *span_list) {
    assert(span_list->head != NULL);

    span_t *head = span_list->head;
    span_list->head = head->next;

    if (span_list->head != NULL) {
        span_list->head->prev = NULL;
    }
    else {
        span_list->tail = NULL;
    }

    _jdz_span_list_reset_span(head);
}