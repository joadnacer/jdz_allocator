include_directories (${TEST_SOURCE_DIR}/src)

add_executable (SpanCacheTest span_cache_test.c)
target_link_libraries (SpanCacheTest SpanCache Span)

add_executable (MpscLargeCacheTest mpsc_large_cache_test.c)
target_link_libraries (MpscLargeCacheTest MpscLargeCache)