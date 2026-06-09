/*
 * GitKit shim — keeps the libgit2 submodule pristine.
 *
 * libgit2's indexer.c defines a file-local `struct entry`. POSIX <search.h>
 * also defines `struct entry` (for hsearch), and SwiftPM's module-based C
 * compilation makes the SDK's <search.h> visible to every translation unit,
 * so clang's cross-TU ODR check rejects libgit2's same-named struct. CMake
 * never hits this (no SDK-module ODR checking).
 *
 * We rename the tag with a #define scoped to THIS translation unit only, then
 * textually include the unmodified upstream source. Because the #define is
 * local to this file, libgit2's public headers — compiled by consumers without
 * it — are untouched, so there is no ABI mismatch. (A package-wide `-Dentry=`
 * would not be safe: ~21 public headers use a bare `entry` identifier.)
 */
#define entry git_indexer_entry
#include "indexer.c"
#undef entry
