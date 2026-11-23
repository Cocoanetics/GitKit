/*
 * GitKit shim — created_dir.c's identity and removal, on Windows.
 *
 * The same promise as on POSIX: a directory is removed only when this
 * operation created it exclusively, it is still that directory, and it
 * holds nothing but the entries the operation writes there, the files the
 * very ones it wrote, unchanged. Everything is by handle and file ID:
 *
 * - A file's identity is its volume serial number and 128-bit file ID;
 *   that it is unchanged, its change and last-write times, size,
 *   attributes and a digest of its contents, all read from one handle. A
 *   reparse point (symlink, junction, placeholder) is never followed or
 *   proven, and neither is a file with another link or a named stream, or
 *   anything on a volume that can't open by file ID (FAT, SMB) or a remote
 *   one: there everything is kept.
 * - A directory to remove is opened (pinned) with delete access, sharing
 *   neither delete nor rename, checked through that handle and renamed by
 *   it to a private name in its own directory, never replacing anything.
 *   Its entries are listed through the handle, each opened by its file ID
 *   (sharing neither write nor delete) and checked; then the listing must
 *   be unchanged. Only when every directory checks out is anything
 *   deleted, children first, each through the handle it was checked by; a
 *   directory that isn't empty by then stays. Otherwise every pin is
 *   closed and each directory renamed back, kept; one whose name was taken
 *   meanwhile stays under its private name.
 */
#include "common.h"

#ifdef GIT_WIN32
#include "rand.h"
#include "hash.h"
#include "win32/path_w32.h"
#include "gitkit_created_dir.h"

/*
 * Newer than the _WIN32_WINNT (Vista) libgit2 builds for: the classes,
 * flags and layouts of Windows 8 and Windows 10 RS1 (minwinbase.h,
 * winbase.h). Where Windows lacks them, the call fails and all is kept.
 */
#define GITKIT_FileRemoteProtocolInfo ((FILE_INFO_BY_HANDLE_CLASS)13)
#define GITKIT_FileIdInfo ((FILE_INFO_BY_HANDLE_CLASS)18)
#define GITKIT_FileIdExtdDirectoryInfo ((FILE_INFO_BY_HANDLE_CLASS)19)
#define GITKIT_FileIdExtdDirectoryRestartInfo ((FILE_INFO_BY_HANDLE_CLASS)20)
#define GITKIT_FileDispositionInfoEx ((FILE_INFO_BY_HANDLE_CLASS)21)
#define GITKIT_ExtendedFileIdType ((FILE_ID_TYPE)2)
#define GITKIT_DISPOSITION_DELETE 0x1
#define GITKIT_DISPOSITION_POSIX_SEMANTICS 0x2
#define GITKIT_SUPPORTS_OPEN_BY_FILE_ID 0x01000000

typedef struct {
	ULONGLONG VolumeSerialNumber;
	BYTE FileId[16];
} gitkit_id_info;			/* FILE_ID_INFO */

typedef struct {
	ULONG NextEntryOffset;
	ULONG FileIndex;
	LARGE_INTEGER CreationTime, LastAccessTime, LastWriteTime, ChangeTime;
	LARGE_INTEGER EndOfFile, AllocationSize;
	ULONG FileAttributes;
	ULONG FileNameLength;
	ULONG EaSize;
	ULONG ReparsePointTag;
	BYTE FileId[16];
	WCHAR FileName[1];
} gitkit_id_extd_dir_info;		/* FILE_ID_EXTD_DIR_INFO */

typedef struct {
	DWORD dwSize;
	FILE_ID_TYPE Type;
	union {
		LARGE_INTEGER FileId;
		GUID ObjectId;
		BYTE ExtendedFileId[16];
	} u;
} gitkit_id_descriptor;			/* FILE_ID_DESCRIPTOR */

/* Bounded retries for what an indexer or virus scanner holds briefly:
 * they only delay, never change what is removed. */
#define GITKIT_RETRIES 10
#define GITKIT_RETRY_MS 5

/* Contents larger than this are not digested, and not provable. */
#define GITKIT_DIGEST_MAX (1024 * 1024)

static int gitkit_transient(DWORD error)
{
	return error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION ||
		error == ERROR_ACCESS_DENIED;
}

static int gitkit_all(const BYTE *bytes, size_t len, BYTE value)
{
	size_t i;

	for (i = 0; i < len; i++)
		if (bytes[i] != value)
			return 0;
	return 1;
}

/* Exactly the unnamed data stream, and nothing else. */
static int gitkit_only_data_stream(HANDLE h)
{
	union { LONGLONG align; BYTE bytes[1024]; } buf;
	const FILE_STREAM_INFO *info = (const FILE_STREAM_INFO *)buf.bytes;
	static const WCHAR data[] = L"::$DATA";

	memset(&buf, 0, sizeof(buf));
	return GetFileInformationByHandleEx(h, FileStreamInfo, &buf, sizeof(buf)) &&
		info->NextEntryOffset == 0 &&
		info->StreamNameLength == sizeof(data) - sizeof(WCHAR) &&
		memcmp(info->StreamName, data, sizeof(data) - sizeof(WCHAR)) == 0;
}

/* SHA-256 of the `size` bytes of the file open at `h`, from its start. */
static int gitkit_digest(unsigned char out[32], HANDLE h, uint64_t size)
{
	LARGE_INTEGER start = { 0 };
	unsigned char *data, extra;
	DWORD got, read = 0;
	int error = -1;

	if (size > GITKIT_DIGEST_MAX ||
	    !SetFilePointerEx(h, start, NULL, FILE_BEGIN) ||
	    (data = git__malloc(size ? (size_t)size : 1)) == NULL)
		return -1;
	while (read < size && ReadFile(h, data + read, (DWORD)size - read, &got, NULL) && got > 0)
		read += got;
	/* All of it, and no more than the size read with it. */
	if (read == size && ReadFile(h, &extra, 1, &got, NULL) && got == 0 &&
	    git_hash_buf(out, data, (size_t)size, GIT_HASH_ALGORITHM_SHA256) == 0)
		error = 0;
	git__free(data);
	return error;
}

/*
 * The identity of what `h` is open on (it must allow reading data).
 * Not provable — `unprovable`, not `present` — unless its volume opens by
 * stable file IDs, it isn't a reparse point and, for a file, it has one
 * link, one data stream, no pending delete and contents to digest.
 */
static void gitkit_id_from_handle(gitkit_file_id *out, HANDLE h)
{
	gitkit_id_info id;
	FILE_BASIC_INFO basic;
	FILE_STANDARD_INFO standard;
	FILE_ATTRIBUTE_TAG_INFO tag;
	union { LONGLONG align; BYTE bytes[1024]; } remote;
	DWORD flags = 0;

	memset(out, 0, sizeof(*out));
	out->unprovable = 1;
	if (!GetFileInformationByHandleEx(h, GITKIT_FileIdInfo, &id, sizeof(id)) ||
	    !GetFileInformationByHandleEx(h, FileBasicInfo, &basic, sizeof(basic)) ||
	    !GetFileInformationByHandleEx(h, FileStandardInfo, &standard, sizeof(standard)) ||
	    !GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, sizeof(tag)) ||
	    !GetVolumeInformationByHandleW(h, NULL, 0, NULL, NULL, &flags, NULL, 0))
		return;
	if (id.VolumeSerialNumber == 0 ||
	    gitkit_all(id.FileId, sizeof(id.FileId), 0) ||
	    gitkit_all(id.FileId, sizeof(id.FileId), 0xff) ||
	    !(flags & GITKIT_SUPPORTS_OPEN_BY_FILE_ID) ||
	    (basic.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
	    (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
	    standard.DeletePending ||
	    GetFileInformationByHandleEx(h, GITKIT_FileRemoteProtocolInfo, &remote, sizeof(remote)))
		return;
	if (!standard.Directory &&
	    (standard.NumberOfLinks != 1 || !gitkit_only_data_stream(h) ||
	     gitkit_digest(out->digest, h, (uint64_t)standard.EndOfFile.QuadPart) < 0))
		return;

	out->dev = (uint64_t)id.VolumeSerialNumber;
	memcpy(&out->ino, id.FileId, sizeof(out->ino));
	memcpy(&out->ino_hi, id.FileId + sizeof(out->ino), sizeof(out->ino_hi));
	out->ctime_sec = (int64_t)basic.ChangeTime.QuadPart;
	out->write_time = (int64_t)basic.LastWriteTime.QuadPart;
	out->size = (uint64_t)standard.EndOfFile.QuadPart;
	out->attributes = (uint32_t)basic.FileAttributes;
	out->present = 1;
	out->unprovable = 0;
}

static int gitkit_is_dir(const gitkit_file_id *id)
{
	return (id->attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

/* `path` without a trailing separator, as a `\\?\` path. */
static int gitkit_wide_path(git_win32_path out, const char *path)
{
	git_str trimmed = GIT_STR_INIT;
	int error;

	if ((error = git_str_sets(&trimmed, path)) == 0) {
		while (git_str_len(&trimmed) > 1 &&
		       (trimmed.ptr[git_str_len(&trimmed) - 1] == '/' ||
		        trimmed.ptr[git_str_len(&trimmed) - 1] == '\\'))
			git_str_shorten(&trimmed, 1);
		error = git_win32_path_from_utf8(out, trimmed.ptr) < 0 ? -1 : 0;
	}
	git_str_dispose(&trimmed);
	return error;
}

void gitkit_created_id(gitkit_file_id *out, const char *path)
{
	git_win32_path wide;
	HANDLE h;
	DWORD error;

	memset(out, 0, sizeof(*out));
	if (gitkit_wide_path(wide, path) < 0) {
		out->unprovable = 1;
		return;
	}
	/* Sharing everything: recording never gets in anyone's way. */
	h = CreateFileW(wide, FILE_READ_ATTRIBUTES | FILE_READ_DATA | SYNCHRONIZE,
	                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
	                OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
	                NULL);
	if (h == INVALID_HANDLE_VALUE) {
		error = GetLastError();
		out->unprovable = error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND;
		return;
	}
	gitkit_id_from_handle(out, h);
	CloseHandle(h);
}

int gitkit_created_same(const gitkit_file_id *id, const gitkit_file_id *now, int with_change)
{
	return id->present && now->present &&
		now->dev == id->dev && now->ino == id->ino && now->ino_hi == id->ino_hi &&
		(!with_change ||
		 (now->ctime_sec == id->ctime_sec && now->write_time == id->write_time &&
		  now->size == id->size && now->attributes == id->attributes &&
		  memcmp(now->digest, id->digest, sizeof(id->digest)) == 0));
}

/* A pinned directory or file: no one else can write, rename or delete it. */
static HANDLE gitkit_pin_path(const wchar_t *path)
{
	HANDLE h;
	int tries = 0;

	while ((h = CreateFileW(path, DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
	                        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
	                        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
	                        NULL)) == INVALID_HANDLE_VALUE &&
	       gitkit_transient(GetLastError()) && ++tries < GITKIT_RETRIES)
		Sleep(GITKIT_RETRY_MS);
	return h;
}

static HANDLE gitkit_pin_id(HANDLE hint, const BYTE file_id[16], int is_dir)
{
	gitkit_id_descriptor descriptor;
	HANDLE h;
	int tries = 0;

	memset(&descriptor, 0, sizeof(descriptor));
	descriptor.dwSize = sizeof(descriptor);
	descriptor.Type = GITKIT_ExtendedFileIdType;
	memcpy(descriptor.u.ExtendedFileId, file_id, sizeof(descriptor.u.ExtendedFileId));
	while ((h = OpenFileById(hint, (LPFILE_ID_DESCRIPTOR)&descriptor,
	                         DELETE | FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
	                         is_dir ? FILE_SHARE_READ | FILE_SHARE_WRITE : FILE_SHARE_READ,
	                         NULL, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT))
	           == INVALID_HANDLE_VALUE &&
	       gitkit_transient(GetLastError()) && ++tries < GITKIT_RETRIES)
		Sleep(GITKIT_RETRY_MS);
	return h;
}

/* Renames what `h` is open on within its directory, replacing nothing. */
static int gitkit_rename(HANDLE h, const wchar_t *name)
{
	size_t bytes = wcslen(name) * sizeof(wchar_t);
	size_t size = sizeof(FILE_RENAME_INFO) + bytes;
	FILE_RENAME_INFO *info = git__calloc(1, size);
	int tries = 0, ok;

	if (info == NULL)
		return -1;
	info->ReplaceIfExists = FALSE;
	info->RootDirectory = NULL;
	info->FileNameLength = (DWORD)bytes;
	memcpy(info->FileName, name, bytes);
	while (!(ok = SetFileInformationByHandle(h, FileRenameInfo, info, (DWORD)size)) &&
	       gitkit_transient(GetLastError()) && ++tries < GITKIT_RETRIES)
		Sleep(GITKIT_RETRY_MS);
	git__free(info);
	return ok ? 0 : -1;
}

/* Deletes what `h` is open on; a directory only while it is empty. */
static int gitkit_delete(HANDLE h)
{
	DWORD flags = GITKIT_DISPOSITION_DELETE | GITKIT_DISPOSITION_POSIX_SEMANTICS;
	FILE_DISPOSITION_INFO classic = { TRUE };
	DWORD error;

	/* Its name goes as the handle closes, even if others have it open. */
	if (SetFileInformationByHandle(h, GITKIT_FileDispositionInfoEx, &flags, sizeof(flags)))
		return 0;
	error = GetLastError();
	if (error != ERROR_INVALID_PARAMETER && error != ERROR_NOT_SUPPORTED &&
	    error != ERROR_INVALID_FUNCTION)
		return -1;
	return SetFileInformationByHandle(h, FileDispositionInfo, &classic, sizeof(classic)) ? 0 : -1;
}

/* One entry of a directory listing. */
typedef struct {
	char *name;
	BYTE file_id[16];
	ULONG attributes;
} gitkit_listed;

typedef struct {
	gitkit_listed *entries;
	size_t len, cap;
} gitkit_listing;

static void gitkit_listing_dispose(gitkit_listing *listing)
{
	size_t i;

	for (i = 0; i < listing->len; i++)
		git__free(listing->entries[i].name);
	git__free(listing->entries);
	memset(listing, 0, sizeof(*listing));
}

static int gitkit_listing_add(gitkit_listing *listing, const gitkit_id_extd_dir_info *info)
{
	int wide_len = (int)(info->FileNameLength / sizeof(WCHAR)), len;
	gitkit_listed *grown, *entry;

	if ((wide_len == 1 && info->FileName[0] == L'.') ||
	    (wide_len == 2 && info->FileName[0] == L'.' && info->FileName[1] == L'.'))
		return 0;
	if (listing->len == listing->cap) {
		listing->cap = listing->cap ? listing->cap * 2 : 16;
		if ((grown = git__reallocarray(listing->entries, listing->cap, sizeof(*grown))) == NULL)
			return -1;
		listing->entries = grown;
	}
	entry = &listing->entries[listing->len];
	/* A name that isn't valid UTF-16 matches nothing: it fails here. */
	if ((len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, info->FileName, wide_len,
	                               NULL, 0, NULL, NULL)) <= 0 ||
	    (entry->name = git__malloc((size_t)len + 1)) == NULL)
		return -1;
	if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, info->FileName, wide_len,
	                        entry->name, len, NULL, NULL) != len) {
		git__free(entry->name);
		return -1;
	}
	entry->name[len] = '\0';
	memcpy(entry->file_id, info->FileId, sizeof(entry->file_id));
	entry->attributes = info->FileAttributes;
	listing->len++;
	return 0;
}

/* The entries of the directory open at `dir`, each with its file ID. */
static int gitkit_list(gitkit_listing *out, HANDLE dir)
{
	FILE_INFO_BY_HANDLE_CLASS klass = GITKIT_FileIdExtdDirectoryRestartInfo;
	const size_t size = 64 * 1024;
	BYTE *buf = git__malloc(size);
	const BYTE *at;
	const gitkit_id_extd_dir_info *info;
	int error = 0;

	memset(out, 0, sizeof(*out));
	if (buf == NULL)
		return -1;
	while (!error) {
		if (!GetFileInformationByHandleEx(dir, klass, buf, (DWORD)size)) {
			if (GetLastError() != ERROR_NO_MORE_FILES)
				error = -1;
			break;
		}
		klass = GITKIT_FileIdExtdDirectoryInfo;
		for (at = buf; !error; at += info->NextEntryOffset) {
			info = (const gitkit_id_extd_dir_info *)at;
			error = gitkit_listing_add(out, info);
			if (info->NextEntryOffset == 0)
				break;
		}
	}
	git__free(buf);
	if (error)
		gitkit_listing_dispose(out);
	return error;
}

/* The same names, each still the same file. */
static int gitkit_same_listing(const gitkit_listing *a, const gitkit_listing *b)
{
	size_t i, j;

	if (a->len != b->len)
		return 0;
	for (i = 0; i < a->len; i++) {
		for (j = 0; j < b->len; j++)
			if (!strcmp(a->entries[i].name, b->entries[j].name))
				break;
		if (j == b->len ||
		    memcmp(a->entries[i].file_id, b->entries[j].file_id, sizeof(a->entries[i].file_id)))
			return 0;
	}
	return 1;
}

/* What a walk pinned, children before their directory. */
typedef struct {
	HANDLE *handles;
	size_t len, cap;
} gitkit_pins;

static int gitkit_pins_add(gitkit_pins *pins, HANDLE h)
{
	HANDLE *grown;

	if (pins->len == pins->cap) {
		pins->cap = pins->cap ? pins->cap * 2 : 16;
		if ((grown = git__reallocarray(pins->handles, pins->cap, sizeof(*grown))) == NULL)
			return -1;
		pins->handles = grown;
	}
	pins->handles[pins->len++] = h;
	return 0;
}

static void gitkit_pins_close(gitkit_pins *pins)
{
	size_t i;

	for (i = 0; i < pins->len; i++)
		CloseHandle(pins->handles[i]);
	git__free(pins->handles);
	memset(pins, 0, sizeof(*pins));
}

static const gitkit_created_entry *gitkit_find_entry(
	const gitkit_created_entry *entries, size_t len, const char *path)
{
	size_t i;

	for (i = 0; i < len; i++)
		if (!strcmp(entries[i].path, path))
			return &entries[i];
	return NULL;
}

/*
 * Checks the directory open at `dir` (at `prefix`): each entry, pinned by
 * its file ID into `pins`, must be one the list names, of its type and,
 * when the list records it, that very file, unchanged; and the listing
 * must still be the same once all are pinned. 0 when it all is the
 * operation's.
 */
static int gitkit_walk(
	HANDLE dir, const char *prefix,
	const gitkit_created_entry *entries, size_t len, gitkit_pins *pins)
{
	gitkit_listing before, after;
	const gitkit_created_entry *entry;
	gitkit_file_id now;
	git_str path = GIT_STR_INIT;
	HANDLE h;
	size_t i;
	int error;

	if (gitkit_list(&before, dir) < 0)
		return -1;
	for (i = 0, error = 0; !error && i < before.len; i++) {
		const gitkit_listed *listed = &before.entries[i];
		int is_dir = (listed->attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;

		git_str_clear(&path);
		if ((*prefix && git_str_printf(&path, "%s/", prefix) < 0) ||
		    git_str_puts(&path, listed->name) < 0 ||
		    (entry = gitkit_find_entry(entries, len, path.ptr)) == NULL ||
		    (listed->attributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
		    entry->is_dir != is_dir ||
		    (h = gitkit_pin_id(dir, listed->file_id, is_dir)) == INVALID_HANDLE_VALUE) {
			error = -1;
			break;
		}
		gitkit_id_from_handle(&now, h);
		if (!now.present || gitkit_is_dir(&now) != is_dir ||
		    memcmp(&now.ino, listed->file_id, sizeof(now.ino)) ||
		    memcmp(&now.ino_hi, listed->file_id + sizeof(now.ino), sizeof(now.ino_hi)) ||
		    (entry->id && !gitkit_created_same(entry->id, &now, !is_dir)) ||
		    (is_dir && gitkit_walk(h, path.ptr, entries, len, pins) < 0)) {
			CloseHandle(h);
			error = -1;
		} else if (gitkit_pins_add(pins, h) < 0) {
			CloseHandle(h);
			error = -1;
		}
	}
	/* With every entry pinned, nothing listed can go or be replaced. */
	if (!error) {
		if (gitkit_list(&after, dir) < 0)
			error = -1;
		else {
			if (!gitkit_same_listing(&before, &after))
				error = -1;
			gitkit_listing_dispose(&after);
		}
	}
	gitkit_listing_dispose(&before);
	git_str_dispose(&path);
	return error;
}

/* One directory being rolled back: pinned, its name, its private name. */
typedef struct {
	HANDLE dir;
	wchar_t name[MAX_PATH];
	wchar_t quarantine[MAX_PATH];
	int moved;
	gitkit_pins pins;
} gitkit_quarantine;

/* Its own name, as it is on disk, from the handle. */
static int gitkit_leaf_name(wchar_t *out, size_t cap, HANDLE h)
{
	const DWORD size = 32768;
	wchar_t *path = git__malloc(size * sizeof(wchar_t)), *leaf;
	DWORD len;
	int error = -1;

	if (path == NULL)
		return -1;
	len = GetFinalPathNameByHandleW(h, path, size, FILE_NAME_NORMALIZED | VOLUME_NAME_NONE);
	if (len > 0 && len < size && (leaf = wcsrchr(path, L'\\')) != NULL &&
	    leaf[1] != L'\0' && wcslen(leaf + 1) < cap) {
		wcscpy(out, leaf + 1);
		error = 0;
	}
	git__free(path);
	return error;
}

/* Pins `dir` and renames it to a private name if it still is `dir->id`. */
static int gitkit_quarantine_dir(gitkit_quarantine *q, const gitkit_created_dir *dir)
{
	git_win32_path wide;
	gitkit_file_id now;
	size_t keep;

	if (!dir->id->present || gitkit_wide_path(wide, dir->path) < 0 ||
	    (q->dir = gitkit_pin_path(wide)) == INVALID_HANDLE_VALUE)
		return -1;
	gitkit_id_from_handle(&now, q->dir);
	if (!gitkit_is_dir(&now) || !gitkit_created_same(dir->id, &now, 0) ||
	    gitkit_leaf_name(q->name, ARRAY_SIZE(q->name), q->dir) < 0)
		return -1;
	/* At most 200 units of the name, not splitting a surrogate pair. */
	keep = wcslen(q->name);
	if (keep > 200)
		keep = IS_HIGH_SURROGATE(q->name[199]) ? 199 : 200;
	if (_snwprintf(q->quarantine, ARRAY_SIZE(q->quarantine), L".%.*ls.gitkit-rollback-%016llx",
	               (int)keep, q->name, (unsigned long long)git_rand_next()) < 0 ||
	    gitkit_rename(q->dir, q->quarantine) < 0)
		return -1;
	q->moved = 1;
	return 0;
}

/* Deletes what the walk pinned, children first, then the directory. */
static int gitkit_delete_quarantined(gitkit_quarantine *q)
{
	size_t i;
	int error = 0;

	for (i = 0; i < q->pins.len; i++) {
		/* Closing a deleted entry's handle takes its name. */
		if (!error && gitkit_delete(q->pins.handles[i]) < 0)
			error = -1;
		CloseHandle(q->pins.handles[i]);
	}
	q->pins.len = 0;
	gitkit_pins_close(&q->pins);
	if (error || gitkit_delete(q->dir) < 0)
		return -1;
	CloseHandle(q->dir);
	q->dir = INVALID_HANDLE_VALUE;
	return 0;
}

int gitkit_remove_created_dirs(const gitkit_created_dir *dirs, size_t len)
{
	gitkit_quarantine q[GITKIT_CREATED_DIRS_MAX];
	git_error *saved = NULL;
	size_t i;
	int result = GITKIT_CREATED_REMOVED, error = 0;

	if (len == 0 || len > GITKIT_CREATED_DIRS_MAX)
		return GITKIT_CREATED_KEPT;
	memset(q, 0, sizeof(q));
	for (i = 0; i < len; i++)
		q[i].dir = INVALID_HANDLE_VALUE;

	git_error_save(&saved);
	/* All or nothing: every directory out of reach and checked first. */
	for (i = 0; !error && i < len; i++)
		error = gitkit_quarantine_dir(&q[i], &dirs[i]);
	for (i = 0; !error && i < len; i++)
		error = gitkit_walk(q[i].dir, "", dirs[i].entries, dirs[i].entries_len, &q[i].pins);
	for (i = 0; !error && i < len; i++) {
		/* Only what appeared since the check can stop this. */
		if (gitkit_delete_quarantined(&q[i]) == 0)
			q[i].moved = 0;
		else
			error = -1;
	}

	/* A directory can't be renamed while anything in it is open. */
	for (i = 0; i < len; i++)
		gitkit_pins_close(&q[i].pins);
	for (i = 0; i < len; i++) {
		if (q[i].moved) {
			if (result == GITKIT_CREATED_REMOVED)
				result = GITKIT_CREATED_KEPT;
			gitkit_created_before_restore(dirs[i].path);
			/* Whatever took its name meanwhile is not replaced: it stays,
			 * and so does this, under its private name. */
			if (gitkit_rename(q[i].dir, q[i].name) < 0)
				result = GITKIT_CREATED_STRANDED;
		}
		if (q[i].dir != INVALID_HANDLE_VALUE)
			CloseHandle(q[i].dir);
	}
	if (error && result == GITKIT_CREATED_REMOVED)
		result = GITKIT_CREATED_KEPT;
	git_error_restore(saved);
	return result;
}

#endif /* GIT_WIN32 */
