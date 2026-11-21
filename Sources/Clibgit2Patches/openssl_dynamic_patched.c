/*
 * libgit2's dynamic TLS backend defines function-pointer variables with the
 * same names as OpenSSL functions (CRYPTO_malloc, SSL_new, etc.). When linked
 * into an ELF executable with exported symbols, OpenSSL's own calls can bind
 * to these data addresses and crash. Hide the definitions from the dynamic
 * loader while preserving their linkage to libgit2's other translation units.
 * Public GIT_EXTERN declarations retain their explicit default visibility.
 * Keep the vendored source pristine and avoid unsafe SwiftPM build flags.
 */
#if defined(GIT_OPENSSL) && defined(GIT_OPENSSL_DYNAMIC)
/* System declarations must keep default visibility (notably dlopen/dlsym). */
#include "common.h"
#include "runtime.h"
#include <dlfcn.h>

#pragma GCC visibility push(hidden)
#include "streams/openssl_dynamic.c"
#pragma GCC visibility pop
#endif
