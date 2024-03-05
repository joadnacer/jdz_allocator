cmake_minimum_required (VERSION 3.6)
project (jdzmalloc)

include_directories(include)
include_directories(src)

add_subdirectory (src) 

enable_testing ()
add_subdirectory (test)
add_test (NAME SpanCacheTest COMMAND SpanCacheTest)
add_test (NAME MpscLargeCacheTest COMMAND MpscLargeCacheTest)