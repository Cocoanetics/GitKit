# GitKit

**[libgit2](https://libgit2.org) as a Swift package — C library and idiomatic
Swift SDK.** GitKit compiles the official libgit2 C sources straight from an
upstream git submodule — no CMake, no system install — and layers a full Swift
API over them, on macOS, iOS, Linux, Windows, and Android.

```swift
import GitKit

let repo = try Repository.open(at: URL(fileURLWithPath: "/path/to/repo"))

let branch = try repo.currentBranch()                     // "main"
let report = try repo.status()                            // git status
try repo.add(paths: ["README.md"])                        // git add
let commit = try repo.commitDetailed(
    message: "Update README",
    author: Signature(name: "Jane", email: "jane@example.com"),
    allowEmpty: false)                                    // git commit
print(commit.shortSHA)

for entry in try repo.log(LogQuery(maxCount: 10)) {       // git log
    print(entry.shortSHA, entry.subject)
}
```

## The Swift SDK

`Repository` mirrors libgit2's own `git_repository *` model: open (or
`initialize` / `clone`) a handle, call operations on it, let ARC free it.
Operations are synchronous, `throws` (typed ``Libgit2Error``), and return
`Sendable` value types. The surface covers the everyday git command set:

- **Lifecycle** — `open`, `initialize` (git init), `clone` (with
  `CredentialProvider` closures for HTTPS/SSH auth and a pluggable progress
  sink).
- **Work** — `add`, `commitDetailed`, `status`, `diff`, `checkout`,
  `checkoutNewBranch`, `checkoutPaths`, `reset`, `move`/`remove` (git mv/rm).
- **History** — `log` (rich `LogQuery`/`LogEntry` incl. `format(_:)`
  placeholders), `blame`, `describe`, `reflog`, `grep`.
- **Branches & refs** — `localBranches`, `branchDelete`/`branchRename`,
  `tagList`/`tagCreate`/`tagCreateAnnotated`/`tagDelete`, `resolveOID`,
  `revParse` helpers, `lsTree`, `catFileBlob`/`objectMetadata`.
- **Integration** — `merge` (fast-forward modes), `rebase`
  (continue/skip/abort), `cherryPick`, `stash`
  (save/apply/pop/list/show/branch), `apply` (patches).
- **Remotes** — `fetch`, `push` (incl. `-u` upstream wiring), `addRemote`,
  `remoteList`, `remoteURL`, real-git-style progress output.

Commit-identity resolution honours real git's `GIT_AUTHOR_*` /
`GIT_COMMITTER_*` env-precedence chain (``SignatureResolver``); pass `env:`
explicitly when you virtualise the environment. The raw C API stays one
property away — `repo.pointer` is a deliberate escape hatch, and the whole
libgit2 C surface remains re-exported (`git_repository_open`, `git_clone`, …)
for anything the SDK doesn't cover yet, with `check(_:)` translating return
codes into thrown ``Libgit2Error``s.

The SDK performs **no access gating and reads no ambient state** — it's a pure
library. Hosts that sandbox file access (e.g.
[SwiftPorts](https://github.com/Cocoanetics/SwiftPorts)' `GitClient`, which
backs its in-process `git` CLI) authorize paths before opening and wrap calls
in their own isolation, composing this SDK rather than configuring it.

## Installation

```swift
.package(url: "https://github.com/cocoanetics/GitKit.git", from: "2.0.0"),
```

```swift
.target(name: "MyApp", dependencies: [.product(name: "GitKit", package: "GitKit")]),
```

SwiftPM initializes the libgit2 submodule automatically when it resolves the
package — there is nothing else to install.

## Versioning

GitKit follows **independent semantic versioning**, and every release states
the libgit2 it vendors:

| GitKit | vendors libgit2 |
|---|---|
| 2.x | v1.9.4 |
| 1.9.4 (legacy) | v1.9.4 |

Up to `1.9.4`, GitKit's version mirrored the libgit2 release 1:1 — the package
was pure packaging, so the numbers could be identical. With the Swift SDK the
package has its own evolution (API additions, fixes) between libgit2 releases,
which a mirrored version number can't express. SDK changes bump GitKit's
major/minor/patch per SemVer; a libgit2 submodule bump is called out in the
release notes (and in this table).

## Supported platforms

| Platform | HTTPS backend | SHA backend | Status |
|---|---|---|---|
| macOS / iOS | SecureTransport | CommonCrypto | ✅ |
| Linux | OpenSSL (dynamic) | builtin (SHA1DC) | ✅ |
| Windows | WinHTTP | Win32 BCrypt | ✅ |
| Android | OpenSSL (dynamic, Bionic) | builtin (SHA1DC) | ✅ |

Every supported platform builds in CI on each push: macOS, Linux, and Windows
also run the test suite; iOS is cross-compiled (`xcodebuild`); Android
cross-compiles and runs its tests on the emulator. The `Package.swift`
re-expresses libgit2's CMake feature detection as a per-platform `-D` matrix
(`LIBGIT2_NO_FEATURES_H` + explicit defines), choosing the native
TLS/hash/NTLM backend for each platform.

> **tvOS / watchOS** are not supported: libgit2's process layer
> (`src/util/unix/process.c`) uses `fork`/`execve`, which Apple marks
> unavailable on those platforms.

## Acknowledgements

GitKit stands on the shoulders of
**[ibrahimcetin/libgit2](https://github.com/ibrahimcetin/libgit2)**, which
pioneered building libgit2 as a SwiftPM target and worked out much of the
per-platform define matrix this package builds on. Huge thanks to İbrahim Çetin
for that groundwork. GitKit's distinct goals are to (a) track libgit2 release
tags 1:1, (b) keep the libgit2 checkout a *pristine* upstream submodule, and
(c) cover Windows and Android.

## The `struct entry` wrangling (why there are two shim files)

libgit2's `src/libgit2/indexer.c` and `deps/xdiff/xpatience.c` each define a
**file-local `struct entry`**. That is perfectly legal C — a struct tag defined
in a `.c` is private to that translation unit, and CMake compiles each `.c`
separately, so the two never meet.

SwiftPM is different. To expose a C target to Swift it compiles the sources as
a **clang module**, which makes the platform SDK module — including POSIX
[`<search.h>`](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/search.h.html),
whose `hsearch` API *also* declares `struct entry` — visible to every
translation unit. clang's cross-TU ODR check then rejects libgit2's same-named
struct:

```
error: type 'struct entry' has incompatible definitions in different translation units
  indexer.c:        field has name 'oid' here
  <search.h>:       field has name 'key' here
```

The fix is a tiny rename of the two file-local tags. But we refuse to modify the
submodule, so each is compiled through a **translation-unit-scoped `#include`
shim** in [`Sources/Clibgit2Patches`](Sources/Clibgit2Patches):

```c
#define entry git_indexer_entry   // scoped to THIS file only
#include "indexer.c"              // the pristine upstream source
#undef entry
```

Because the `#define` lives only in the shim's translation unit, libgit2's
public headers — compiled by *your* code without the define — are untouched, so
there is no ABI mismatch. (A package-wide `-Dentry=…` is **not** safe: a bare
`entry` identifier appears in ~21 of libgit2's public headers, and `util.c`
genuinely uses `<search.h>`.)

### Why this isn't a build-tool plugin

The obvious instinct is "use a SwiftPM build plugin to rewrite the two files
before compiling." **It cannot work:** SwiftPM refuses to compile
plugin-generated C sources. Both plugin modes (`buildCommand` and
`prebuildCommand`) emit

```
warning: C source file generation not enabled: …/indexer.c
```

and then silently drop the generated file, so the build fails at link with
undefined `git_indexer_*` symbols. There is no flag to enable it (verified on
Swift 6.3). Plugin-generated **Swift** is compiled; C/C++/Objective-C is not.
The `#include` shim sidesteps the limitation entirely — it's an ordinary
checked-in source file, so SwiftPM compiles it normally.

## The curated module and vendored headers (Windows, and why the submodule stays pristine)

libgit2's public headers assume two things the Windows MSVC/clang-cl toolchain
doesn't provide: a lowercase `ssize_t` (used by `git2/sys/stream.h`), and that
its bundled VS2008-era `git2/stdint.h` polyfill won't fight the real
`<stdint.h>`. Upstream forks fix these by editing the headers — we don't, so the
submodule stays byte-for-byte pristine.

Two SwiftPM facts shape the solution:

1. To import a C target into Swift, SwiftPM builds a **clang module**. The
   auto-generated *umbrella-directory* module map pulls in *every* header in the
   target's `publicHeadersPath` — including the vestigial `git2/stdint.h`, which
   then collides with the system `<stdint.h>` on Windows.
2. That module build **only searches the target's `publicHeadersPath`** — never
   its `cSettings` header paths. So a `-Dssize_t=…` define or a header-search
   path can't reach it, and the public headers it needs can't be pointed at from
   elsewhere.

So `GitKit` imports **`CGitKit`**, a curated module whose `publicHeadersPath`
contains a custom umbrella header plus **byte copies of libgit2's public
headers** ([`Sources/CGitKit/include`](Sources/CGitKit/include)). The umbrella
includes `git2.h` (so the `git2/stdint.h` polyfill is never in the module) and
applies the `ssize_t` / `_MSC_STDINT_H_` shims *before* it — fixing Windows for
every consumer, not just CI. The copies are re-synced from the pinned submodule
by [`Scripts/update-libgit2.sh`](Scripts/update-libgit2.sh) on each version bump.

libgit2's **`.c` are still compiled from the pristine submodule** (the `Clibgit2`
target, whose `publicHeadersPath` is a header-free dir so SwiftPM builds no
module over libgit2's raw `include/`). Only the public *headers* are vendored, so
the Swift importer has something to read.

## The feature-define dialect (a silent-failure trap)

With no CMake there is no feature *detection*: `LIBGIT2_NO_FEATURES_H` plus an
explicit per-platform `-D` matrix replaces it. The trap is that **the define
names are not stable across libgit2 versions** — and a `-D` the source never
reads doesn't warn, it just leaves the feature compiled out.

libgit2 renamed much of its feature matrix on `main` after the 1.9 series
([libgit2/libgit2#6994](https://github.com/libgit2/libgit2/pull/6994)):

| 1.9.x reads | main (post-#6994) reads |
|---|---|
| `GIT_USE_NSEC` / `GIT_USE_STAT_MTIMESPEC` / `GIT_USE_STAT_MTIM` | `GIT_NSEC` / `GIT_NSEC_MTIMESPEC` / `GIT_NSEC_MTIM` |
| `GIT_USE_FUTIMENS` | `GIT_FUTIMENS` |
| `GIT_USE_ICONV` | `GIT_I18N_ICONV` |
| `GIT_NTLM` | `GIT_AUTH_NTLM` |
| `GIT_SECURE_TRANSPORT` / `GIT_OPENSSL` / `GIT_WINHTTP` | `GIT_HTTPS_SECURETRANSPORT` / `GIT_HTTPS_OPENSSL_DYNAMIC` / `GIT_HTTPS_WINHTTP` |

GitKit's original matrix was inherited from the ibrahimcetin fork — which, it
turned out, builds a libgit2 *main* snapshot rather than the release its branch
name suggests. So the matrix spoke main's post-rename dialect while GitKit
pinned the `v1.9.4` release, and every renamed define silently no-op'd. The
first GitKit `1.9.4` build shipped with **nanosecond timestamps off** — which
broke `git_stash_apply`/`pop`/`branch` (a working-tree change made in the same
second as the index write is invisible to stat-based comparison, so apply
"succeeded" without writing anything) — and, equally silently, with **no TLS
backend selected** (`GIT_HTTPS` was on with nothing behind it), NTLM off, and
iconv off. Nothing failed at compile time; a downstream stash test caught it
([#1](https://github.com/Cocoanetics/GitKit/issues/1), fixed in
[#2](https://github.com/Cocoanetics/GitKit/pull/2), the `1.9.4` tag re-pointed
to the fixed build).

The rules that came out of it:

- The matrix must speak the **pinned release's** dialect — it is
  version-dependent, not copy-paste-portable between libgit2 lines.
- On every submodule bump, **audit every `-D`** against the pinned source:
  each name must actually appear in `vendor/libgit2/{src,include,deps}`
  (`*.c`/`*.h`). Zero hits = silent no-op. (Exceptions: macros consumed by
  *system* headers — `_GNU_SOURCE`, `OPENSSL_API_COMPAT`, `_WIN32_WINNT`.)
- A bump past the rename (a future 1.10/2.x) must translate the matrix
  *forward* again.

## Repository layout

```
GitKit/
├── Package.swift                 # the per-platform build of libgit2
├── Sources/
│   ├── GitKit/                   # the Swift SDK (Repository + operations)
│   │                             #   + re-export of the full C API
│   ├── CGitKit/                  # curated umbrella + vendored libgit2 public headers
│   └── Clibgit2Patches/          # two #include shims (struct entry rename)
├── Tests/GitKitTests/            # the SDK test suite (exercises real repos)
└── vendor/libgit2/               # submodule → libgit2/libgit2 @ vX.Y.Z (pristine)
```

`Clibgit2` (libgit2's compiled `.c`), `CGitKit` (the imported module), and
`Clibgit2Patches` are internal; `GitKit` and `CGitKit` are the products.

## Updating to a new libgit2 release

A libgit2 bump ships as a regular GitKit release (minor or major per SemVer,
noted in the release notes and the versioning table above):

```sh
Scripts/update-libgit2.sh vX.Y.Z      # moves the submodule to the tag, re-vendors headers
# audit the -D matrix against the new tag (see "The feature-define dialect"):
#   every define in Package.swift must appear in vendor/libgit2/{src,include,deps}
swift test                            # verify on this host
git commit -am "libgit2 X.Y.Z"
git tag <next GitKit version> && git push --tags
```

The script repoints the pristine submodule and re-vendors the public headers.
The `struct entry` shims are layout-dependent only (revisit if libgit2 moves
files or adds a new same-named-struct collision) — but the **define matrix is
version-dependent**: libgit2 renames feature defines between lines, and a stale
name fails silently (see above). Audit it on every bump.

## License

GitKit's own code (the manifest, the umbrella, the shims, and the Swift wrapper)
is released under the MIT license — see [LICENSE](LICENSE). libgit2's source is
fetched as a submodule from
[libgit2/libgit2](https://github.com/libgit2/libgit2); its public headers are
also vendored under [`Sources/CGitKit/include/git2`](Sources/CGitKit/include) as
byte copies. Both are libgit2's own files, licensed under **GPLv2 with a linking
exception** — see libgit2's `COPYING` for the terms that apply to the library
and its headers.
