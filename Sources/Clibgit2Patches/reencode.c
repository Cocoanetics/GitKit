/*
 * GitKit shim — git's reencode_string_len() (utf8.c): convert a commit
 * message between any two charsets iconv knows, as git does when it rewrites
 * a commit whose `encoding` differs from i18n.commitEncoding. Plain C so it
 * can pick up iconv where the platform has it. Declared for Swift in
 * CGitKit's gitkit_libgit2.h.
 */
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32) || (defined(__ANDROID__) && __ANDROID_API__ < 28)
# define GITKIT_NO_ICONV 1
#else
# include <iconv.h>
#endif

int gitkit_reencode(
	char **out,
	size_t *out_len,
	const char *in,
	size_t in_len,
	const char *to,
	const char *from)
{
#ifdef GITKIT_NO_ICONV
	(void)in; (void)in_len; (void)to; (void)from;
	*out = NULL;
	*out_len = 0;
	return -2;
#else
	iconv_t conv;
	char *buf, *outp, *inp = (char *)in;
	size_t insz = in_len, outsz, outalloc;

	*out = NULL;
	*out_len = 0;
	if ((conv = iconv_open(to, from)) == (iconv_t)-1)
		return -2;

	/* Grow the output like git's reencode_string_iconv(). */
	outalloc = in_len + 1;
	if ((buf = malloc(outalloc)) == NULL) {
		iconv_close(conv);
		return -1;
	}
	outp = buf;
	outsz = outalloc - 1;

	while (1) {
		size_t cnt = iconv(conv, &inp, &insz, &outp, &outsz);

		if (cnt == (size_t)-1) {
			size_t used = outp - buf;
			char *grown;

			if (errno != E2BIG) {
				free(buf);
				iconv_close(conv);
				return -1;
			}
			outalloc = outalloc * 2 + 16;
			if ((grown = realloc(buf, outalloc)) == NULL) {
				free(buf);
				iconv_close(conv);
				return -1;
			}
			buf = grown;
			outp = buf + used;
			outsz = outalloc - used - 1;
		} else {
			*outp = '\0';
			break;
		}
	}

	iconv_close(conv);
	*out = buf;
	*out_len = outp - buf;
	return 0;
#endif
}
