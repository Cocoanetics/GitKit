/*
 * GitKit shim — libgit2's wildmatch (git's own, src/util/wildmatch.c) for
 * Swift, which matches sparse-checkout patterns as git does. libgit2 keeps
 * it internal, so it is exported here. Declared for Swift in CGitKit's
 * gitkit_libgit2.h.
 */
#include "wildmatch.h"

int gitkit_wildmatch(const char *pattern, const char *text, unsigned int flags)
{
	return wildmatch(pattern, text, flags);
}
