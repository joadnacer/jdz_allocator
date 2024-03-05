#include <stdbool.h>
#include <stdio.h>
#include <errno.h>

static int ok = 0;
static int failed = 0;

static bool check_result(bool result, const char* testname, const char* fname, long lineno) {
  if (!(result)) {
    failed++;
    fprintf(stderr,"\n  FAILED: %s: %s:%ld\n", testname, fname, lineno);
  }
  else {
    ok++;
    fprintf(stderr, "ok.\n");
  }
  return true;
}

#define TEST(name) \
  fprintf(stderr,"test: %s...  ", name ); \
  errno = 0; \
  for(bool done = false, result = true; !done; done = check_result(result,name,__FILE__,__LINE__))

static inline int print_test_summary(void)
{
  fprintf(stderr,"\n\n---------------------------------------------\n"
                 "succeeded: %i\n"
                 "failed   : %i\n\n", ok, failed);
  return failed;
}