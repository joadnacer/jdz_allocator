#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

# define JDZMALLOC_EXPORT __attribute__((visibility("default")))
# define JDZMALLOC_ALLOCATOR

# if (defined(__clang_major__) && (__clang_major__ < 4)) || (defined(__GNUC__) && defined(ENABLE_PRELOAD) && ENABLE_PRELOAD)
# define JDZMALLOC_ATTRIB_MALLOC
# define JDZMALLOC_ATTRIB_ALLOC_SIZE(size)
# define JDZMALLOC_ATTRIB_ALLOC_SIZE2(count, size)
# else
# define JDZMALLOC_ATTRIB_MALLOC __attribute__((__malloc__))
# define JDZMALLOC_ATTRIB_ALLOC_SIZE(size) __attribute__((alloc_size(size)))
# define JDZMALLOC_ATTRIB_ALLOC_SIZE2(count, size)  __attribute__((alloc_size(count, size)))
# endif

typedef struct jdzmalloc_config_t {
    //! controls batch span allocation amount for one span allocations
    //! will return 1 span to allocating function and all remaining spans will be written to the one span cache
    size_t span_alloc_count;

    //! controls batch memory mapping amount in spans
    //! overhead from desired span count will be saved to map_cache for reuse on future map requests
    //! as memory mapping will likely not be aligned, we will use 1 span worth of padding per map call
    //! padding may be used as a span if alignment allows it
    //! minimum is 1 (not recommended) - default is 64, resulting in 4MiB memory mapping + 64KiB padding
    size_t map_alloc_count;

    //! maximum number of spans in arena cache
    size_t cache_limit;

    //! maximum number spans in arena large caches
    size_t large_cache_limit;

    //! percentage overhead applied to span count when looking for a large span in cache
    //! increases cache hits and memory usage, but does hurt performance
    float large_span_overhead_mul;

    //! cache large spans as normal spans if self.large_cache_upper_limit is hit
    int recycle_large_spans;

    //! if cached large spans should be split to accomodate small or medium allocations
    //! improves memory usage but hurts performance
    int split_large_spans_to_one;

    //! if cached large spans should be split to accomodate smaller large allocations
    //! improves memory usage but hurts performance
    int split_large_spans_to_large;
} jdzmalloc_config_t;

//! Initialize allocator with default configuration
JDZMALLOC_EXPORT int
jdzmalloc_initialize(void);

//! Initialize allocator with given configuration
JDZMALLOC_EXPORT int
jdzmalloc_initialize_config(const jdzmalloc_config_t* config);

//! Get allocator configuration
JDZMALLOC_EXPORT const jdzmalloc_config_t*
jdzmalloc_config(void);

//! Finalize allocator
JDZMALLOC_EXPORT void
jdzmalloc_finalize(void);

//! Initialize allocator for calling thread
JDZMALLOC_EXPORT void
jdzmalloc_thread_initialize(void);

//! Finalize allocator for calling thread
JDZMALLOC_EXPORT void
jdzmalloc_thread_finalize(int release_caches);

//! Perform deferred deallocations pending for the calling thread heap
JDZMALLOC_EXPORT void
jdzmalloc_thread_collect(void);

//! Query if allocator is initialized for calling thread
JDZMALLOC_EXPORT int
jdzmalloc_is_thread_initialized(void);

//! Allocate a memory block of at least the given size
JDZMALLOC_EXPORT JDZMALLOC_ALLOCATOR void*
jdzmalloc(size_t size) JDZMALLOC_ATTRIB_MALLOC JDZMALLOC_ATTRIB_ALLOC_SIZE(1);

//! Free the given memory block
JDZMALLOC_EXPORT void
jdzfree(void* ptr);

//! Allocate a memory block of at least the given size and zero initialize it
JDZMALLOC_EXPORT JDZMALLOC_ALLOCATOR void*
jdzcalloc(size_t num, size_t size) JDZMALLOC_ATTRIB_MALLOC JDZMALLOC_ATTRIB_ALLOC_SIZE2(1, 2);

//! Reallocate the given block to at least the given size
JDZMALLOC_EXPORT JDZMALLOC_ALLOCATOR void*
jdzrealloc(void* ptr, size_t size) JDZMALLOC_ATTRIB_MALLOC JDZMALLOC_ATTRIB_ALLOC_SIZE(2);

//! Reallocate the given block to at least the given size and alignment,
//  with optional control flags (see JDZMALLOC_NO_PRESERVE).
//  Alignment must be a power of two and a multiple of sizeof(void*),
//  and should ideally be less than memory page size. A caveat of jdzmalloc
//  internals is that this must also be strictly less than the span size (default 64KiB)
JDZMALLOC_EXPORT JDZMALLOC_ALLOCATOR void*
jdzaligned_realloc(void* ptr, size_t alignment, size_t size, size_t oldsize, unsigned int flags) JDZMALLOC_ATTRIB_MALLOC JDZMALLOC_ATTRIB_ALLOC_SIZE(3);

//! Allocate a memory block of at least the given size and alignment.
//  Alignment must be a power of two and a multiple of sizeof(void*),
//  and should ideally be less than memory page size. A caveat of jdzmalloc
//  internals is that this must also be strictly less than the span size (default 64KiB)
JDZMALLOC_EXPORT JDZMALLOC_ALLOCATOR void*
jdzaligned_alloc(size_t alignment, size_t size) JDZMALLOC_ATTRIB_MALLOC JDZMALLOC_ATTRIB_ALLOC_SIZE(2);

//! Allocate a memory block of at least the given size and alignment, and zero initialize it.
//  Alignment must be a power of two and a multiple of sizeof(void*),
//  and should ideally be less than memory page size. A caveat of jdzmalloc
//  internals is that this must also be strictly less than the span size (default 64KiB)
JDZMALLOC_EXPORT JDZMALLOC_ALLOCATOR void*
jdzaligned_calloc(size_t alignment, size_t num, size_t size) JDZMALLOC_ATTRIB_MALLOC JDZMALLOC_ATTRIB_ALLOC_SIZE2(2, 3);

//! Allocate a memory block of at least the given size and alignment.
//  Alignment must be a power of two and a multiple of sizeof(void*),
//  and should ideally be less than memory page size. A caveat of jdzmalloc
//  internals is that this must also be strictly less than the span size (default 64KiB)
JDZMALLOC_EXPORT JDZMALLOC_ALLOCATOR void*
jdzmemalign(size_t alignment, size_t size) JDZMALLOC_ATTRIB_MALLOC JDZMALLOC_ATTRIB_ALLOC_SIZE(2);

//! Allocate a memory block of at least the given size and alignment.
//  Alignment must be a power of two and a multiple of sizeof(void*),
//  and should ideally be less than memory page size. A caveat of jdzmalloc
//  internals is that this must also be strictly less than the span size (default 64KiB)
JDZMALLOC_EXPORT int
jdzposix_memalign(void** memptr, size_t alignment, size_t size);

//! Query the usable size of the given memory block (from given pointer to the end of block)
JDZMALLOC_EXPORT size_t
jdzmalloc_usable_size(void* ptr);

//! Dummy empty function for forcing linker symbol inclusion
JDZMALLOC_EXPORT void
jdzmalloc_linker_reference(void);

#ifdef __cplusplus
}
#endif