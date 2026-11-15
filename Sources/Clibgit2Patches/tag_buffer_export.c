/*
 * GitKit shim — the unsigned text of an annotated tag, without writing it.
 * Formats exactly as libgit2's write_tag_annotation (src/libgit2/tag.c) and
 * has the signature upstream proposes as git_tag_create_buffer
 * (libgit2/libgit2#4969); drop it once libgit2 ships that API. Recheck the
 * format whenever the vendored libgit2 changes. Declared for Swift in
 * CGitKit's gitkit_libgit2.h.
 */
#include "buf.h"
#include "object.h"
#include "signature.h"

int gitkit_tag_create_buffer(
	git_buf *out,
	git_repository *repo,
	const char *tag_name,
	const git_object *target,
	const git_signature *tagger,
	const char *message)
{
	git_str tag = GIT_STR_INIT;
	int error;

	GIT_ASSERT_ARG(out);
	GIT_ASSERT_ARG(repo);
	GIT_ASSERT_ARG(tag_name);
	GIT_ASSERT_ARG(target);
	GIT_ASSERT_ARG(tagger);
	GIT_ASSERT_ARG(message);

	if (git_object_owner(target) != repo) {
		git_error_set(GIT_ERROR_INVALID, "the given target does not belong to this repository");
		return -1;
	}

	if ((error = git_buf_tostr(&tag, out)) < 0 ||
	    (error = git_object__write_oid_header(&tag, "object ", git_object_id(target))) < 0)
		goto done;

	git_str_printf(&tag, "type %s\n", git_object_type2string(git_object_type(target)));
	git_str_printf(&tag, "tag %s\n", tag_name);
	git_signature__writebuf(&tag, "tagger ", tagger);
	git_str_putc(&tag, '\n');

	if ((error = git_str_puts(&tag, message)) < 0)
		goto done;

	error = git_buf_fromstr(out, &tag);

done:
	git_str_dispose(&tag);
	return error;
}
