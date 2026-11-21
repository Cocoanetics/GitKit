#if os(Linux) && canImport(Glibc)
import Glibc
import Testing
import GitKit

struct OpenSSLSymbolTests {
    /// An exported libgit2 data symbol must never replace an OpenSSL function.
    /// No network or TLS server is needed: creating SSL_CTX exercises OpenSSL's
    /// allocation calls, which jumped into CRYPTO_malloc data before #85.
    @Test func dynamicOpenSSLDoesNotInterposeSystemFunctions() throws {
        GitKit.initialize()
        defer { GitKit.shutdown() }
        let process = try #require(dlopen(nil, RTLD_NOW))
        defer { dlclose(process) }
        let ssl = try #require(dlopen("libssl.so.3", RTLD_NOW)
                               ?? dlopen("libssl.so.1.1", RTLD_NOW))
        defer { dlclose(ssl) }

        // Include the NTLM backend's entry points: its pointers are stored in
        // ntlm_crypt_ctx, and its legacy HMAC helpers have static linkage.
        for name in ["CRYPTO_malloc", "CRYPTO_free", "SSL_new", "SSL_CTX_new",
                     "BIO_new", "ERR_get_error", "HMAC_CTX_new", "HMAC_CTX_free",
                     "HMAC_CTX_reset", "HMAC_Init_ex", "DES_set_key", "MD4"] {
            let exported = dlsym(process, name)
            let system = dlsym(ssl, name)
            #expect(exported == nil || exported == system,
                    "\(name) interposes the system OpenSSL function")
        }

        typealias TLSMethod = @convention(c) () -> OpaquePointer?
        typealias ContextNew = @convention(c) (OpaquePointer?) -> OpaquePointer?
        typealias ContextFree = @convention(c) (OpaquePointer?) -> Void
        let method = unsafeBitCast(try #require(dlsym(ssl, "TLS_method")), to: TLSMethod.self)
        let create = unsafeBitCast(try #require(dlsym(ssl, "SSL_CTX_new")), to: ContextNew.self)
        let free = unsafeBitCast(try #require(dlsym(ssl, "SSL_CTX_free")), to: ContextFree.self)
        let context = try #require(create(method()))
        free(context)
    }
}
#endif
