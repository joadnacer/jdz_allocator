#pragma once

#include "internal.h"

#define IS_POWER_OF_TWO(x) ((x & (x - 1)) == 0)

#define GET_SPAN_COUNT(x) (((x - 1) / SPAN_SIZE) * SPAN_SIZE + SPAN_SIZE) / SPAN_SIZE