// swift-tools-version: 5.9
import PackageDescription

// =============================================================================
// GitKit — libgit2, packaged for SwiftPM.
//
//   • libgit2 is a git submodule (vendor/libgit2) pinned to an official
//     upstream release tag. GitKit's own version always matches it (see README).
//   • `Clibgit2` compiles libgit2's C directly (no CMake) via
//     LIBGIT2_NO_FEATURES_H + the per-host `-D` matrix below, which
//     re-expresses libgit2's CMake feature detection.
//   • Two files (indexer.c, xdiff/xpatience.c) define a file-local
//     `struct entry` that collides with POSIX <search.h>'s `struct entry`
//     under SwiftPM's module-based C build. They are compiled through
//     translation-unit-scoped `#include` shims (Sources/Clibgit2shim) so the
//     submodule stays byte-for-byte pristine. See README ("The struct entry
//     wrangling") for why a build plugin can't do this.
//   • Consumers only import `GitKit`.
// =============================================================================

let libgit2 = "vendor/libgit2"

// Preprocessor defines — libgit2's feature matrix. Shared by the core target
// and the shim target (the shim compiles two libgit2 .c files, so it needs the
// same feature flags). Header search paths are kept separate (they differ
// between the two targets) — see coreHeaderPaths / shimHeaderPaths.
var defines: [CSetting] = [
    .define("LIBGIT2_NO_FEATURES_H"),
    .define("GIT_THREADS", to: "1"),
    .define("GIT_THREADS_PTHREADS", to: "1",
            .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux, .android])),
    .define("GIT_ARCH_64", to: "1"),

    // PCRE (builtin regex)
    .define("GIT_REGEX_BUILTIN", to: "1"),
    .define("SUPPORT_PCRE8", to: "1"),
    .define("HAVE_STDINT_H", to: "1"),
    .define("HAVE_INTTYPES_H", to: "1"),
    .define("HAVE_MEMMOVE", to: "1"),
    .define("HAVE_STRERROR", to: "1"),
    .define("LINK_SIZE", to: "2"),
    .define("PARENS_NEST_LIMIT", to: "250"),
    .define("MATCH_LIMIT", to: "10000000"),
    .define("MATCH_LIMIT_RECURSION", to: "10000000"),
    .define("NEWLINE", to: "10"),
    .define("NO_RECURSE", to: "1"),
    .define("POSIX_MALLOC_THRESHOLD", to: "10"),
    .define("BSR_ANYCRLF", to: "0"),
    .define("MAX_NAME_SIZE", to: "32"),
    .define("MAX_NAME_COUNT", to: "10000"),

    // SSH transport (exec-based; not on Windows/Android).
    .define("GIT_SSH", to: "1", .when(platforms: [.macOS, .iOS, .linux])),
    .define("GIT_SSH_EXEC", to: "1", .when(platforms: [.macOS, .iOS, .linux])),

    .define("GIT_HTTPPARSER_BUILTIN", to: "1"),
    .define("GIT_HTTPS", to: "1",
            .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux, .android, .windows])),
    .define("GIT_IO_POLL", to: "1",
            .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux, .android])),
    .define("GIT_IO_WSAPOLL", to: "1", .when(platforms: [.windows])),
    .define("GIT_NSEC", to: "1"),
    .define("GIT_FUTIMENS", to: "1",
            .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux, .android])),

    .define("GIT_AUTH_NTLM", to: "1"),
    .define("GIT_AUTH_NTLM_BUILTIN", to: "1",
            .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux, .android])),
    .define("GIT_AUTH_NTLM_SSPI", to: "1", .when(platforms: [.windows])),
    .define("NTLM_STATIC", to: "1",
            .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux, .android])),
    .define("UNICODE_BUILTIN", to: "1",
            .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux, .android])),

    .define("GIT_COMPRESSION_BUILTIN", to: "1"),
]

// CMake/build-system files and unused backends, plus the two files we compile
// through the shims instead.
var excludes: [String] = [
    "deps/llhttp/CMakeLists.txt", "deps/llhttp/LICENSE-MIT",
    "deps/pcre/CMakeLists.txt", "deps/pcre/COPYING", "deps/pcre/LICENCE",
    "deps/pcre/cmake", "deps/pcre/config.h.in",
    "deps/xdiff/CMakeLists.txt",
    "deps/zlib/CMakeLists.txt", "deps/zlib/LICENSE",
    "deps/ntlmclient/CMakeLists.txt",
    "src/libgit2/CMakeLists.txt", "src/libgit2/experimental.h.in",
    "src/libgit2/git2.rc", "src/libgit2/config.cmake.in",
    "src/util/CMakeLists.txt", "src/util/git2_features.h.in",
    "src/util/hash/mbedtls.c", "src/util/hash/mbedtls.h",
    "deps/ntlmclient/crypt_mbedtls.c", "deps/ntlmclient/crypt_mbedtls.h",
    "deps/ntlmclient/crypt_builtin_md4.c",
    "deps/ntlmclient/unicode_iconv.c", "deps/ntlmclient/unicode_iconv.h",

    // Compiled via Sources/Clibgit2shim/*_patched.c (struct entry rename).
    "src/libgit2/indexer.c",
    "deps/xdiff/xpatience.c",
]

// Header search paths, relative to each target's own directory.
var coreHeaderPaths: [CSetting] = [
    .headerSearchPath("deps/llhttp"),
    .headerSearchPath("deps/pcre"),
    .headerSearchPath("deps/xdiff"),
    .headerSearchPath("deps/zlib"),
    .headerSearchPath("deps/ntlmclient"),
    .headerSearchPath("src/libgit2"),
    .headerSearchPath("src/util"),
]
// The shims live in Sources/Clibgit2shim and reach back into the pristine
// submodule to resolve libgit2's own headers. (The builtin-SHA paths needed on
// Linux/Android are appended in the host-dispatch block below.)
var shimHeaderPaths: [CSetting] = [
    .headerSearchPath("../../\(libgit2)/src/libgit2"),
    .headerSearchPath("../../\(libgit2)/src/util"),
    .headerSearchPath("../../\(libgit2)/deps/xdiff"),
    .headerSearchPath("../../\(libgit2)/deps/llhttp"),
    .headerSearchPath("../../\(libgit2)/deps/pcre"),
    .headerSearchPath("../../\(libgit2)/deps/ntlmclient"),
    .headerSearchPath("../../\(libgit2)/deps/zlib"),
    .headerSearchPath("../../\(libgit2)/include"),
]

var linkerSettings: [LinkerSetting] = []

// -----------------------------------------------------------------------------
// Host dispatch. `#if os(...)` selects the source-exclusion set for the build
// host; `.when(platforms:)` above refines defines per target platform.
//   macOS host → Apple targets · Linux host → Linux + Android · Windows host.
// -----------------------------------------------------------------------------
#if os(macOS)
    excludes += [
        "src/util/hash/win32.c", "src/util/hash/win32.h", "src/util/win32",
        "src/util/hash/builtin.c", "src/util/hash/builtin.h",
        "src/util/hash/collisiondetect.c", "src/util/hash/collisiondetect.h",
        "src/util/hash/rfc6234", "src/util/hash/sha1dc",
        "src/util/hash/openssl.c", "src/util/hash/openssl.h",
        "deps/ntlmclient/crypt_openssl.c", "deps/ntlmclient/crypt_openssl.h",
    ]
    defines += [
        .define("GIT_QSORT_BSD"),
        .define("GIT_HTTPS_SECURETRANSPORT", to: "1"),
        .define("GIT_SHA1_COMMON_CRYPTO", to: "1"),
        .define("GIT_SHA256_COMMON_CRYPTO", to: "1"),
        .define("CRYPT_COMMONCRYPTO"),
        .define("GIT_NSEC_MTIMESPEC", to: "1"),
        .define("GIT_I18N", to: "1"),
        .define("GIT_I18N_ICONV", to: "1"),
        .define("GIT_NO_PROCESS_SPAWN", .when(platforms: [.tvOS, .watchOS])),
    ]
    linkerSettings += [.linkedLibrary("iconv")]

#elseif os(Windows)
    excludes += [
        "src/util/unix", "deps/ntlmclient",
        "src/util/hash/common_crypto.c", "src/util/hash/common_crypto.h",
        "deps/ntlmclient/crypt_commoncrypto.c", "deps/ntlmclient/crypt_commoncrypto.h",
        "src/util/hash/builtin.c", "src/util/hash/builtin.h",
        "src/util/hash/collisiondetect.c", "src/util/hash/collisiondetect.h",
        "src/util/hash/rfc6234", "src/util/hash/sha1dc",
        "src/util/hash/openssl.c", "src/util/hash/openssl.h",
        "deps/ntlmclient/crypt_openssl.c", "deps/ntlmclient/crypt_openssl.h",
        "deps/winhttp",
    ]
    defines += [
        .define("GIT_QSORT_MSC"),
        .define("GIT_HTTPS_WINHTTP", to: "1"),
        .define("GIT_SHA1_WIN32", to: "1"),
        .define("GIT_SHA256_WIN32", to: "1"),
        .define("CRYPT_BUILTIN"),
        .define("GIT_NSEC_WIN32", to: "1"),
        .define("WIN32"),
        .define("_WIN32_WINNT", to: "0x0600"),
    ]
    linkerSettings += [
        .linkedLibrary("ws2_32"), .linkedLibrary("secur32"),
        .linkedLibrary("winhttp"), .linkedLibrary("rpcrt4"),
        .linkedLibrary("crypt32"), .linkedLibrary("ole32"), .linkedLibrary("bcrypt"),
    ]

#else // Linux / Android
    excludes += [
        "src/util/hash/win32.c", "src/util/hash/win32.h", "src/util/win32",
        "src/util/hash/common_crypto.c", "src/util/hash/common_crypto.h",
        "deps/ntlmclient/crypt_commoncrypto.c", "deps/ntlmclient/crypt_commoncrypto.h",
    ]
    defines += [
        .define("_GNU_SOURCE"),
        .define("GIT_QSORT_GNU", .when(platforms: [.linux])),
        .define("GIT_HTTPS_OPENSSL_DYNAMIC", to: "1", .when(platforms: [.linux, .android])),
        .define("GIT_SHA1_BUILTIN", to: "1"),
        .define("GIT_SHA256_BUILTIN", to: "1"),
        .define("SHA1DC_NO_STANDARD_INCLUDES", to: "1"),
        .define("SHA1DC_CUSTOM_INCLUDE_SHA1_C", to: "\"git2_util.h\""),
        .define("SHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C", to: "\"git2_util.h\""),
        .define("CRYPT_OPENSSL", .when(platforms: [.linux, .android])),
        .define("CRYPT_OPENSSL_DYNAMIC", .when(platforms: [.linux, .android])),
        .define("OPENSSL_API_COMPAT", to: "0x10100000L", .when(platforms: [.linux, .android])),
        .define("GIT_NSEC_MTIM", to: "1"),
        .define("GIT_RAND_GETENTROPY", to: "1", .when(platforms: [.linux, .android])),
        .define("GIT_RAND_GETLOADAVG", to: "1", .when(platforms: [.linux])),
    ]
    coreHeaderPaths += [
        .headerSearchPath("src/util/hash/sha1dc"),
        .headerSearchPath("src/util/hash/rfc6234"),
    ]
    // The shim compiles indexer.c, which pulls in hash.h → the builtin SHA
    // backend on Linux/Android, so it needs the same hash header paths.
    shimHeaderPaths += [
        .headerSearchPath("../../\(libgit2)/src/util/hash/sha1dc"),
        .headerSearchPath("../../\(libgit2)/src/util/hash/rfc6234"),
    ]
    linkerSettings += [
        .linkedLibrary("z"),
        .linkedLibrary("dl"),
        .linkedLibrary("pthread", .when(platforms: [.linux])),
    ]
#endif

let package = Package(
    name: "GitKit",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
    products: [
        .library(name: "GitKit", targets: ["GitKit"]),
    ],
    targets: [
        // Public Swift face — the only module consumers import.
        .target(name: "GitKit", dependencies: ["Clibgit2"]),

        // libgit2 itself, compiled from the pristine submodule.
        .target(
            name: "Clibgit2",
            dependencies: ["Clibgit2shim"],
            path: libgit2,
            exclude: excludes,
            sources: [
                "deps/llhttp", "deps/pcre", "deps/xdiff", "deps/zlib",
                "deps/ntlmclient", "src/libgit2", "src/util",
            ],
            publicHeadersPath: "include",
            cSettings: coreHeaderPaths + defines,
            linkerSettings: linkerSettings
        ),

        // The two `struct entry` files, compiled through TU-scoped #include
        // shims so the submodule needs no edits.
        .target(
            name: "Clibgit2shim",
            path: "Sources/Clibgit2shim",
            publicHeadersPath: ".",
            cSettings: shimHeaderPaths + defines
        ),

        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
    ]
)
