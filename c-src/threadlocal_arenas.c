#include <threadlocal_arenas.h>

#include <pthread.h>

// TODO: look into this comment from mimalloc prim.h
/* ----------------------------------------------------------------------------------------
The thread local default heap: `_mi_prim_get_default_heap()`
This is inlined here as it is on the fast path for allocation functions.

On most platforms (Windows, Linux, FreeBSD, NetBSD, etc), this just returns a
__thread local variable (`_mi_heap_default`). With the initial-exec TLS model this ensures
that the storage will always be available (allocated on the thread stacks).

On some platforms though we cannot use that when overriding `malloc` since the underlying
TLS implementation (or the loader) will call itself `malloc` on a first access and recurse.
We try to circumvent this in an efficient way:
- macOSX : we use an unused TLS slot from the OS allocated slots (MI_TLS_SLOT). On OSX, the
           loader itself calls `malloc` even before the modules are initialized.
- OpenBSD: we use an unused slot from the pthread block (MI_TLS_PTHREAD_SLOT_OFS).
- DragonFly: defaults are working but seem slow compared to freeBSD (see PR #323)
------------------------------------------------------------------------------------------- */

///
/// Thread arena
///
#if ((defined(__APPLE__) || defined(__HAIKU__)) && ENABLE_PRELOAD) || defined(__TINYC__)
static pthread_key_t _thread_arena = (pthread_key_t) NULL; // TODO: is this correct? 
#else
#  ifdef _MSC_VER
#    define _jdz_decl_thread __declspec(thread)
#    define TLS_MODEL
#  else
#    define _jdz_decl_thread __thread
#    ifndef __HAIKU__
#      define TLS_MODEL __attribute__((tls_model("initial-exec")))
#    else
#      define TLS_MODEL
#    endif
#  endif
static _jdz_decl_thread void* _thread_arena TLS_MODEL = NULL;
#endif

inline void* _jdz_get_thread_arena(void) {
#if (defined(__APPLE__) || defined(__HAIKU__)) && ENABLE_PRELOAD
	return pthread_getspecific(_thread_arena);
#else
	return _thread_arena;
#endif
}

inline void _jdz_set_thread_arena(void *arena) {
#if (defined(__APPLE__) || defined(__HAIKU__)) && ENABLE_PRELOAD
	pthread_setspecific(_thread_arena, arena);
#else
	_thread_arena = arena;
#endif
}
