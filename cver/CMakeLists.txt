cmake_minimum_required (VERSION 3.6)
project (jdzmalloc)

include_directories(include)
include_directories(src)

add_subdirectory (src) 

add_library(MallocShared SHARED
    src/arena.c
    src/deferred_span_list.c
    src/jdzmalloc.c
    src/malloc.c
    src/mpsc_large_cache.c
    src/span_cache.c
    src/span_list.c
    src/span.c
)



enable_testing ()
add_subdirectory (test)
add_test (NAME SpanCacheTest COMMAND SpanCacheTest)
add_test (NAME MpscLargeCacheTest COMMAND MpscLargeCacheTest)