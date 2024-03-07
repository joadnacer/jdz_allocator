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

//! Initialize allocator with default configuration
JDZMALLOC_EXPORT int
jdzmalloc_init(void);

//! Deinit allocator
JDZMALLOC_EXPORT void
jdzmalloc_deinit(void);

//! Initialize arena for calling thread
JDZMALLOC_EXPORT void
jdzmalloc_thread_init(void);

//! Deinit arena for calling thread
JDZMALLOC_EXPORT void
jdzmalloc_thread_deinit(int release_caches);

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