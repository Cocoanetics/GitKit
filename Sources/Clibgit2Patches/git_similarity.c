/*
 * GitKit shim — git's rename similarity (diffcore-delta.c's span hashes and
 * diffcore-rename.c's estimate_similarity) as a libgit2 similarity metric, so
 * renames found by git_diff_find_similar carry the percentages git prints.
 * libgit2's own hashsig metric scores differently (95% where git says 94%).
 * Declared for Swift in CGitKit's gitkit_libgit2.h.
 */
#include "common.h"
#include "futils.h"
#include "git2/diff.h"

#define GITKIT_MAX_SCORE 60000
#define GITKIT_HASHBASE 107927
#define GITKIT_FIRST_FEW_BYTES 8000

struct gitkit_span {
	unsigned int hashval;
	unsigned int cnt;
};

struct gitkit_similarity_sig {
	size_t size;
	size_t count;
	struct gitkit_span *spans;
};

static int span_cmp(const void *a, const void *b)
{
	unsigned int x = ((const struct gitkit_span *)a)->hashval;
	unsigned int y = ((const struct gitkit_span *)b)->hashval;
	return x < y ? -1 : x > y;
}

/* git's buffer_is_binary(): a NUL in the first 8000 bytes. */
static int is_binary(const unsigned char *buf, size_t size)
{
	return memchr(buf, 0, size < GITKIT_FIRST_FEW_BYTES ? size : GITKIT_FIRST_FEW_BYTES) != NULL;
}

/* git's hash_chars(): spans ending at a newline or after 64 bytes, each
 * hashed, their byte counts summed per hash. */
static int signature_for(void **out, const unsigned char *buf, size_t size)
{
	struct gitkit_similarity_sig *sig;
	struct gitkit_span *spans;
	size_t count = 0, alloc = 64, i, j;
	unsigned int accum1 = 0, accum2 = 0, n = 0;
	int is_text = !is_binary(buf, size);
	size_t sz = size;

	*out = NULL;
	spans = git__malloc(alloc * sizeof(*spans));
	GIT_ERROR_CHECK_ALLOC(spans);

	while (sz || n) {
		if (sz) {
			unsigned int c = *buf++;
			unsigned int old_1 = accum1;
			sz--;

			/* Ignore CR in CRLF sequence if text */
			if (is_text && c == '\r' && sz && *buf == '\n')
				continue;

			accum1 = (accum1 << 7) ^ (accum2 >> 25);
			accum2 = (accum2 << 7) ^ (old_1 >> 25);
			accum1 += c;
			if (++n < 64 && c != '\n')
				continue;
		}
		if (count == alloc) {
			struct gitkit_span *grown;
			alloc *= 2;
			grown = git__realloc(spans, alloc * sizeof(*spans));
			if (!grown) {
				git__free(spans);
				return -1;
			}
			spans = grown;
		}
		spans[count].hashval = (accum1 + accum2 * 0x61) % GITKIT_HASHBASE;
		spans[count].cnt = n;
		count++;
		n = 0;
		accum1 = accum2 = 0;
	}

	/* One entry per hash, its counts summed, as git's spanhash table. */
	qsort(spans, count, sizeof(*spans), span_cmp);
	for (i = 0, j = 0; i < count; i++) {
		if (j > 0 && spans[j - 1].hashval == spans[i].hashval)
			spans[j - 1].cnt += spans[i].cnt;
		else
			spans[j++] = spans[i];
	}

	sig = git__calloc(1, sizeof(*sig));
	if (!sig) {
		git__free(spans);
		return -1;
	}
	sig->size = size;
	sig->count = j;
	sig->spans = spans;
	*out = sig;
	return 0;
}

static int file_signature(void **out, const git_diff_file *file, const char *fullpath, void *payload)
{
	git_str buf = GIT_STR_INIT;
	int error;

	GIT_UNUSED(file);
	GIT_UNUSED(payload);
	if ((error = git_futils_readbuffer(&buf, fullpath)) < 0)
		return error;
	error = signature_for(out, (const unsigned char *)buf.ptr, buf.size);
	git_str_dispose(&buf);
	return error;
}

static int buffer_signature(
	void **out, const git_diff_file *file, const char *buf, size_t buflen, void *payload)
{
	GIT_UNUSED(file);
	GIT_UNUSED(payload);
	return signature_for(out, (const unsigned char *)buf, buflen);
}

static void free_signature(void *sig, void *payload)
{
	GIT_UNUSED(payload);
	if (sig) {
		git__free(((struct gitkit_similarity_sig *)sig)->spans);
		git__free(sig);
	}
}

/* git's diffcore_count_changes() and estimate_similarity(): the source's
 * bytes the target keeps, over the larger size; `a` is the source. */
static int similarity(int *score, void *siga, void *sigb, void *payload)
{
	const struct gitkit_similarity_sig *src = siga, *dst = sigb;
	size_t s = 0, d = 0, max_size;
	unsigned long long copied = 0;

	GIT_UNUSED(payload);
	max_size = src->size > dst->size ? src->size : dst->size;
	if (max_size == 0) {
		*score = 100;
		return 0;
	}
	while (s < src->count && d < dst->count) {
		if (src->spans[s].hashval < dst->spans[d].hashval) {
			s++;
		} else if (dst->spans[d].hashval < src->spans[s].hashval) {
			d++;
		} else {
			unsigned int sc = src->spans[s].cnt, dc = dst->spans[d].cnt;
			copied += sc < dc ? sc : dc;
			s++;
			d++;
		}
	}
	/* git keeps the score out of MAX_SCORE and prints it out of 100. */
	*score = (int)((int)(copied * GITKIT_MAX_SCORE / max_size) * 100 / GITKIT_MAX_SCORE);
	return 0;
}

void gitkit_git_similarity_metric(git_diff_similarity_metric *out)
{
	out->file_signature = file_signature;
	out->buffer_signature = buffer_signature;
	out->free_signature = free_signature;
	out->similarity = similarity;
	out->payload = NULL;
}
