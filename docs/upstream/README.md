# Upstream libgit2 submissions

Clean patches for libgit2, ready to offer upstream. **No upstream PR has been
opened.** They are written against libgit2 `main` as vendored here (v1.9.4) and
`git apply` in `vendor/libgit2`; each carries its commit message and a clar test
(`tests/libgit2/config/include.c`). The clar tests have not been built against
libgit2's own test runner — the GitKit shim in
`Sources/Clibgit2Patches/config_file_patched.c` is what is built and tested here.

1. `0001` — set/unset consider only the target file's entries (GitKit's
   `ConfigIncludeTests`).
2. `0002` — a callback to refuse include files, through `git_libgit2_opts()`.
   Process-wide, the simplest upstream shape; GitKit's shim is per repository
   (`ConfigIncludePolicy`), which upstream would hang off the config backend.
3. `0003` — `get_entry()` freed through an uninitialised pointer when a backend
   `get` failed; found while making a refused include fail a config reload.

Once upstream issues exist, add their numbers to the shim's comment and the
README, as for libgit2/libgit2#7435 and #7437.
