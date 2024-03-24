#define _GNU_SOURCE

#include "libjdzglobal.h"

#include <pthread.h>
#include <dlfcn.h>  


pthread_key_t _jdz_default_key = (pthread_key_t) -1;

static void _jdz_thread_destructor(void* value) {
    jdz_deinit_thread();
}

void __attribute__ ((constructor)) setup(void) {
    pthread_key_create(&_jdz_default_key, &_jdz_thread_destructor);
}

int (*pthread_create_orig)(pthread_t *, const pthread_attr_t *, void *(*) (void *), void *);

int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start) (void *), void *arg) {
    if (!pthread_create_orig)
        pthread_create_orig = dlsym(RTLD_NEXT, "pthread_create");
        
    pthread_setspecific(_jdz_default_key, (void*)1 );
    return pthread_create_orig(thread, attr, start, arg);
}
