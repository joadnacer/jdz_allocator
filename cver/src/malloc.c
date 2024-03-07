#include "jdzmalloc.h"

extern inline void* malloc(size_t size) { return jdzmalloc(size); }
extern inline void free(void* ptr) { jdzfree(ptr); }

#if defined(__clang__) || defined(__GNUC__)

static void __attribute__((constructor))
initializer(void) {
	jdzmalloc_init();
}

#elif defined(_MSC_VER)

static int
_global_rpmalloc_xib(void) {
	jdzmalloc_init();
	return 0;
}

#endif