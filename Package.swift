// swift-tools-version: 5.9
import PackageDescription

// =============================================================================
// GitKit — libgit2, packaged for SwiftPM.
//
//   • libgit2 is a git submodule (vendor/libgit2) pinned to an official upstream
//     release tag, and is compiled byte-for-byte pristine — no edits, ever.
//     GitKit's own version always matches the libgit2 release (see README).
//   • `Clibgit2` compiles libgit2's C directly (no CMake) via
//     LIBGIT2_NO_FEATURES_H + the per-host `-D` matrix below. Its
//     publicHeadersPath points at a header-free dir, so SwiftPM builds NO
//     module over libgit2's raw include/ (whose auto umbrella-directory would
//     drag in the vestigial git2/stdint.h polyfill and break on Windows).
//   • `CGitKit` is the curated module consumers import. SwiftPM's C-module
//     build only searches a target's publicHeadersPath (never cSettings header
//     paths), so libgit2's public headers are *vendored* next to a custom
//     umbrella in Sources/CGitKit/include (re-synced per release by
//     Scripts/update-libgit2.sh — the submodule stays pristine). The umbrella
//     includes git2.h (not the stdint.h polyfill) and applies the two Windows
//     (MSVC/clang-cl) shims before it.
//   • indexer.c / xdiff/xpatience.c define a file-local `struct entry` that
//     collides with POSIX <search.h> under SwiftPM's module C build; they're
//     compiled via translation-unit-scoped `#include` shims (Clibgit2Patches).
//   • Consumers only import `GitKit`.
// =============================================================================

let libgit2 = "vendor/libgit2"

// Preprocessor defines — libgit2's feature matrix. Shared by the libgit2 target
// and the struct-entry shim target (which compiles two libgit2 .c files).
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

// Files NOT to compile, relative to the submodule (Clibgit2's path).
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

    // Compiled via Sources/Clibgit2Patches/*_patched.c (struct entry rename).
    "src/libgit2/indexer.c",
    "deps/xdiff/xpatience.c",
]

// Header search paths for the .c compilation, relative to Clibgit2's path
// (the submodule). The .c compile against the pristine submodule headers.
var coreHeaderPaths: [CSetting] = [
    .headerSearchPath("include"),
    .headerSearchPath("deps/llhttp"),
    .headerSearchPath("deps/pcre"),
    .headerSearchPath("deps/xdiff"),
    .headerSearchPath("deps/zlib"),
    .headerSearchPath("deps/ntlmclient"),
    .headerSearchPath("src/libgit2"),
    .headerSearchPath("src/util"),
]
// The shims live in Sources/Clibgit2Patches and reach into the pristine submodule.
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
        // libgit2's public headers assume two things MSVC/clang-cl doesn't
        // provide. The curated umbrella applies the same shims for the Swift
        // module; these defines cover libgit2's own .c compilation:
        //  • `ssize_t` → ptrdiff_t (same width); used by git2/sys/stream.h.
        .define("ssize_t", to: "ptrdiff_t"),
        //  • skip libgit2's bundled VS2008-era <stdint.h> polyfill so the real
        //    system <stdint.h> wins (no int16_t/etc. redefinition).
        .define("_MSC_STDINT_H_", to: "1"),
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
        // We hash via collisiondetect (SHA1) + builtin/rfc6234 (SHA256), not the
        // OpenSSL hash backend. In 1.9.4 the rfc6234 `SHA1` enum collides with
        // <openssl/sha.h>'s `SHA1()` if this TU is compiled, so drop it.
        "src/util/hash/openssl.c", "src/util/hash/openssl.h",
    ]
    defines += [
        .define("_GNU_SOURCE"),
        .define("GIT_QSORT_GNU", .when(platforms: [.linux])),
        .define("GIT_HTTPS_OPENSSL_DYNAMIC", to: "1", .when(platforms: [.linux, .android])),
        // libgit2 1.9.4 selects the collision-detecting builtin SHA1 via
        // GIT_SHA1_COLLISIONDETECT (older releases used GIT_SHA1_BUILTIN).
        .define("GIT_SHA1_COLLISIONDETECT", to: "1"),
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
    // tvOS/watchOS are intentionally omitted: libgit2's process layer
    // (src/util/unix/process.c) calls fork/execve, which Apple marks
    // unavailable there.
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "GitKit", targets: ["GitKit"]),
        // The curated libgit2 C module (git2.h API, Windows-safe), for C/Swift
        // consumers that want the raw API directly — e.g. SwiftPorts' SwiftGit.
        .library(name: "CGitKit", targets: ["CGitKit"]),
    ],
    targets: [
        // Public Swift face — the only module consumers import.
        .target(name: "GitKit", dependencies: ["CGitKit"]),

        // The curated, Windows-safe libgit2 module: a custom umbrella over the
        // vendored public headers (Sources/CGitKit/include). Links the compiled
        // libgit2 via its dependency on Clibgit2.
        .target(
            name: "CGitKit",
            dependencies: ["Clibgit2"],
            path: "Sources/CGitKit",
            publicHeadersPath: "include",
            cSettings: defines
        ),

        // libgit2 itself, compiled from the pristine submodule. publicHeadersPath
        // is a header-free dir so no module is generated over its raw include/.
        .target(
            name: "Clibgit2",
            dependencies: ["Clibgit2Patches"],
            path: libgit2,
            exclude: excludes,
            sources: [
                "deps/llhttp", "deps/pcre", "deps/xdiff", "deps/zlib",
                "deps/ntlmclient", "src/libgit2", "src/util",
            ],
            publicHeadersPath: "ci",
            cSettings: coreHeaderPaths + defines,
            linkerSettings: linkerSettings
        ),

        // The two `struct entry` files, compiled through TU-scoped #include
        // shims so the submodule needs no edits.
        .target(
            name: "Clibgit2Patches",
            path: "Sources/Clibgit2Patches",
            publicHeadersPath: ".",
            cSettings: shimHeaderPaths + defines
        ),

        .testTarget(name: "GitKitTests", dependencies: ["GitKit"]),
    ]
)
