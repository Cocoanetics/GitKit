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
| macOS / iOS / tvOS / watchOS | SecureTransport | CommonCrypto | ✅ built & tested |
| Linux | OpenSSL (dynamic) | builtin (SHA1DC) | 🧪 CI |
| Windows | WinHTTP | Win32 BCrypt | 🚧 arm present — needs public-header shims |
| Android | OpenSSL (dynamic, Bionic) | builtin (SHA1DC) | 🚧 arm present — CI pending |

The `Package.swift` re-expresses libgit2's CMake feature detection as a
per-platform `-D` matrix (`LIBGIT2_NO_FEATURES_H` + explicit defines), choosing
the native TLS/hash/NTLM backend for each platform. The Apple arm is built and
tested here; the Windows and Android arms are ported from a configuration proven
downstream in [SwiftPorts](https://github.com/Cocoanetics/SwiftPorts).

### Roadmap

- **Windows:** libgit2's public `common.h` / `stdint.h` need two small
  MSVC-compatibility tweaks (alias `ssize_t`, defer to the system `<stdint.h>`).
  Since the submodule stays pristine, these will land as force-included shim
  headers rather than source edits.
- **Android:** wire the cross-compile job (mirroring SwiftPorts' emulator CI).

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

## Repository layout

```
GitKit/
├── Package.swift                 # the per-platform build of libgit2
├── Sources/
│   ├── GitKit/                   # public Swift module (re-exports the C API)
│   └── Clibgit2shim/             # two #include shims (the only "patch")
├── Tests/GitKitTests/
└── vendor/libgit2/               # submodule → libgit2/libgit2 @ vX.Y.Z (pristine)
```

`Clibgit2` (the libgit2 C target) and `Clibgit2shim` are internal; `GitKit` is
the only product.

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

GitKit's own code (the manifest, shims, and Swift wrapper) is released under the
MIT license — see [LICENSE](LICENSE). libgit2 itself is **not** vendored here;
it is fetched as a submodule from
[libgit2/libgit2](https://github.com/libgit2/libgit2) under its own license
(GPLv2 **with a linking exception**). Review libgit2's `COPYING` for the terms
that apply to the compiled library.
