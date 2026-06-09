# GitKit

**[libgit2](https://libgit2.org) as a Swift package.** GitKit compiles the
official libgit2 C sources straight from an upstream git submodule — no CMake,
no system install — and exposes them to Swift on macOS, iOS, tvOS, watchOS,
Linux, Windows, and Android.

```swift
import GitKit

print(GitKit.libgit2Version)        // "1.9.4"
GitKit.initialize()
defer { GitKit.shutdown() }

var repo: OpaquePointer?
git_repository_open(&repo, "/path/to/repo")   // full libgit2 C API, re-exported
```

## Installation

```swift
.package(url: "https://github.com/cocoanetics/GitKit.git", from: "1.9.4"),
```

```swift
.target(name: "MyApp", dependencies: [.product(name: "GitKit", package: "GitKit")]),
```

SwiftPM initializes the libgit2 submodule automatically when it resolves the
package — there is nothing else to install.

## Versioning — GitKit tracks libgit2 exactly

**GitKit's version number is always identical to the libgit2 release it wraps.**
GitKit `1.9.4` builds libgit2 `v1.9.4`; GitKit `1.8.5` builds libgit2 `v1.8.5`.
There is no independent GitKit version line — when libgit2 ships an official
release tag, GitKit ships the same number with the submodule pinned to that tag.

So `from: "1.9.4"` means *"libgit2 1.9.4, packaged for Swift"*, and a SemVer
range maps directly onto libgit2 releases. Patch/minor bumps follow libgit2's
own.

## Supported platforms

| Platform | HTTPS backend | SHA backend | Status |
|---|---|---|---|
| macOS / iOS / tvOS / watchOS | SecureTransport | CommonCrypto | ✅ |
| Linux | OpenSSL (dynamic) | builtin (SHA1DC) | ✅ |
| Windows | WinHTTP | Win32 BCrypt | ✅ |
| Android | OpenSSL (dynamic, Bionic) | builtin (SHA1DC) | ✅ |

Every declared platform builds in CI on each push: macOS, Linux, and Windows
also run the test suite; iOS, tvOS, and watchOS are cross-compiled (`xcodebuild`,
generic device destinations); Android cross-compiles and runs its tests on the
emulator. The `Package.swift` re-expresses libgit2's CMake feature detection as a
per-platform `-D` matrix (`LIBGIT2_NO_FEATURES_H` + explicit defines), choosing
the native TLS/hash/NTLM backend for each platform.

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
shim** in [`Sources/Clibgit2shim`](Sources/Clibgit2shim):

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

## Repository layout

```
GitKit/
├── Package.swift                 # the per-platform build of libgit2
├── Sources/
│   ├── GitKit/                   # public Swift module (re-exports the C API)
│   ├── CGitKit/                  # curated umbrella + vendored libgit2 public headers
│   └── Clibgit2shim/             # two #include shims (struct entry rename)
├── Tests/GitKitTests/
└── vendor/libgit2/               # submodule → libgit2/libgit2 @ vX.Y.Z (pristine)
```

`Clibgit2` (libgit2's compiled `.c`), `CGitKit` (the imported module), and
`Clibgit2shim` are internal; `GitKit` is the only product.

## Updating to a new libgit2 release

GitKit releases follow libgit2 releases. To cut GitKit `X.Y.Z`:

```sh
Scripts/update-libgit2.sh vX.Y.Z      # moves the submodule to the tag
swift test                            # verify on this host
git commit -am "libgit2 X.Y.Z"
git tag X.Y.Z && git push --tags
```

The script only repoints the pristine submodule; the shims and manifest are
version-independent (revisit them only if libgit2 changes its source layout or
introduces a new same-named-struct collision).

## License

GitKit's own code (the manifest, the umbrella, the shims, and the Swift wrapper)
is released under the MIT license — see [LICENSE](LICENSE). libgit2's source is
fetched as a submodule from
[libgit2/libgit2](https://github.com/libgit2/libgit2); its public headers are
also vendored under [`Sources/CGitKit/include/git2`](Sources/CGitKit/include) as
byte copies. Both are libgit2's own files, licensed under **GPLv2 with a linking
exception** — see libgit2's `COPYING` for the terms that apply to the library
and its headers.
