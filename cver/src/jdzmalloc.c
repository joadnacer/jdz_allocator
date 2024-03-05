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
        medium_size_classes[i].block_size = (i + 1) * MEDIUM_GRANULARITY;
        medium_size_classes[i].block_max = SPAN_EFFECTIVE_SIZE / medium_size_classes[i].block_size;
        medium_size_classes[i].class_idx = i;
    }

    _jdz_merge_size_classes(medium_size_classes, MEDIUM_CLASS_COUNT);

    assert(medium_size_classes[0].block_size == MEDIUM_GRANULARITY);
    assert(medium_size_classes[MEDIUM_CLASS_COUNT - 1].block_size == MEDIUM_MAX);
}
