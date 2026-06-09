/*
 * GitKit shim — see indexer_patched.c for the full rationale.
 *
 * deps/xdiff/xpatience.c defines its own file-local `struct entry` that
 * likewise collides with POSIX <search.h>. Same translation-unit-scoped
 * rename, leaving the submodule byte-for-byte pristine.
 */
#define entry xdl_patience_entry
#include "xpatience.c"
#undef entry
