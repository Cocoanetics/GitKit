import Foundation
import Testing
@testable import GitKit

// No platform gate: injected signing must work everywhere GitKit builds.
@Suite("Commit signing with an injected signer", .serialized)
struct CommitSigningTests {
    /// Shared with real-program parity tests, which exercise the fallback.
    static let signerDefaultsLock = NSLock()
    private let fixtures = TemporaryRepositories()
    private static let environment = [
        "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@e.com", "GIT_AUTHOR_DATE": "1767258000 +0100",
        "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@e.com", "GIT_COMMITTER_DATE": "1767258000 +0100"
    ]

    // The SDK invokes this synchronously on the calling thread. These
    // recorders are confined to one test, including callbacks into a repo.
    final class Signer: GitSigner, @unchecked Sendable {
        var requests: [SigningRequest] = []
        var payloads: [[UInt8]] = []
        var callback: (([UInt8], SigningRequest) throws -> String)?
        let armor: String

        init(_ armor: String = "opaque signature\nsecond line\n") { self.armor = armor }

        func sign(_ payload: [UInt8], request: SigningRequest) throws -> String {
            requests.append(request)
            payloads.append(payload)
            return try callback?(payload, request) ?? armor
        }
    }

    private func repository() throws -> Repository {
        let repo = try Repository.initialize(at: fixtures.directory("repo"), initialBranch: "main")
        try repo.configSet("commit.gpgsign", "false")
        return repo
    }

    @discardableResult
    private func commit(_ repo: Repository, sign: SignMode = .config) throws -> Libgit2CommitDetails {
        try repo.commitDetailed(message: "signed\n", author: nil, allowEmpty: true,
                                env: Self.environment, sign: sign)
    }

    private func rawCommit(_ repo: Repository, _ sha: String) throws -> [UInt8] {
        var oid = git_oid()
        try check(git_oid_fromstr(&oid, sha))
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, repo.repo))
        defer { git_odb_free(odb) }
        var object: OpaquePointer?
        try check(git_odb_read(&object, odb, &oid))
        defer { git_odb_object_free(object) }
        return Array(UnsafeRawBufferPointer(start: git_odb_object_data(object), count: git_odb_object_size(object)))
    }

    @Test("repository signer wins, then process default; fallback can be disabled")
    func signerPrecedence() throws {
        Self.signerDefaultsLock.lock()
        defer { Self.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let repo = try repository()
        let local = Signer("local\n")
        let global = Signer("global\n")
        GitSigning.setExternalProgramFallbackEnabled(false)
        Signer.setDefault(global)
        defer {
            GitSigning.setDefault(nil)
            GitSigning.setExternalProgramFallbackEnabled(true)
        }
        repo.setSigner(local)
        let localCommit = try commit(repo, sign: .sign(keyID: nil))
        #expect(String(decoding: try rawCommit(repo, localCommit.sha), as: UTF8.self).contains("gpgsig local\n"))
        #expect(local.requests.count == 1)
        #expect(global.requests.isEmpty)
        global.callback = { _, _ in
            // The registry lock must have been released before sign().
            GitSigning.setExternalProgramFallbackEnabled(false)
            return "global\n"
        }
        repo.setSigner(nil)
        _ = try commit(repo, sign: .sign(keyID: nil))
        #expect(global.requests.count == 1)
        GitSigning.setDefault(nil)
        #expect(throws: SigningError.noSigner(.openpgp)) { try commit(repo, sign: .sign(keyID: nil)) }
        // No signer is needed when signing is off.
        _ = try commit(repo, sign: .noSign)
    }

    @Test("explicit modes ignore invalid signing config and pass the explicit key unchanged")
    func explicitModes() throws {
        defer { fixtures.removeAll() }
        let repo = try repository()
        try repo.configSet("commit.gpgsign", "not-a-bool")
        try repo.configSet("gpg.format", "invalid")
        try repo.configSet("gpg.program", "must-not-run")
        try repo.configSet("user.signingkey", "wrong-key")
        let signer = Signer()
        repo.setSigner(signer)
        let unsigned = try commit(repo, sign: .noSign)
        #expect(!String(decoding: try rawCommit(repo, unsigned.sha), as: UTF8.self).contains("gpgsig"))
        #expect(signer.requests.isEmpty)
        _ = try commit(repo, sign: .sign(keyID: "~/explicit-key"))
        let request = try #require(signer.requests.first)
        #expect(request.key == "~/explicit-key")
        #expect(request.format == .openpgp)
        #expect(request.program == nil)
        #expect(request.defaultKeyCommand == nil)
        #expect(request.identity == "T <t@e.com>")
        _ = try commit(repo, sign: .sign(keyID: nil))
        #expect(signer.requests.last?.key == nil)
    }

    @Test("config passes unexpanded keys, program overrides and opaque armor")
    func configuredSigning() throws {
        defer { fixtures.removeAll() }
        let repo = try repository()
        let signer = Signer("-----BEGIN SSH SIGNATURE-----\nopaque\n-----END SSH SIGNATURE-----\n")
        repo.setSigner(signer)
        try repo.configSet("commit.gpgsign", "true")
        try repo.configSet("gpg.format", "openpgp")
        try repo.configSet("user.signingkey", "~/key")
        try repo.configSet("gpg.program", "~/bin/legacy-gpg")
        try repo.configSet("gpg.ssh.defaultKeyCommand", "shell-key-command")
        _ = try commit(repo)
        #expect(signer.requests.last?.program?.replacingOccurrences(of: "\\", with: "/")
            .hasSuffix("/bin/legacy-gpg") == true)
        #expect(signer.requests.last?.program?.contains("~") == false)
        try repo.configSet("gpg.openpgp.program", "~/bin/new-gpg")
        let result = try commit(repo)
        let request = try #require(signer.requests.last)
        #expect(request.key == "~/key")
        #expect(request.program?.replacingOccurrences(of: "\\", with: "/").hasSuffix("/bin/new-gpg") == true)
        #expect(request.program?.contains("~") == false)
        #expect(request.defaultKeyCommand == "shell-key-command")
        let text = String(decoding: try rawCommit(repo, result.sha), as: UTF8.self)
        #expect(text.contains("gpgsig -----BEGIN SSH SIGNATURE-----\n opaque\n -----END SSH SIGNATURE-----\n"))
        for format in [SigningFormat.ssh, .x509] {
            try repo.configSet("gpg.format", format.rawValue)
            try repo.configSet("gpg.\(format.rawValue).program", "~/bin/custom-\(format.rawValue)")
            _ = try commit(repo)
            #expect(signer.requests.last?.format == format)
            #expect(signer.requests.last?.program?.replacingOccurrences(of: "\\", with: "/")
                .hasSuffix("/bin/custom-\(format.rawValue)") == true)
            #expect(signer.requests.last?.program?.contains("~") == false)
        }
    }

    @Test("OpenPGP program aliases follow config precedence")
    func programAliasPrecedence() throws {
        defer { fixtures.removeAll() }
        let repo = try repository()
        try repo.configSet("commit.gpgsign", "true")
        try repo.configSet("gpg.openpgp.program", "~/bin/lower-specific")
        let higherURL = fixtures.url("higher-config")
        try Data("[gpg]\n program = ~/bin/higher-generic\n".utf8).write(to: higherURL)
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo.repo))
        defer { git_config_free(config) }
        try check(git_config_add_file_ondisk(config, higherURL.path, GIT_CONFIG_LEVEL_APP, repo.repo, 0))
        let signer = Signer()
        repo.setSigner(signer)

        _ = try commit(repo)

        #expect(signer.requests.last?.program?.replacingOccurrences(of: "\\", with: "/")
            .hasSuffix("/bin/higher-generic") == true)
    }

    @Test("config uses a level added to the open repository, and resolves tag defaults separately")
    func addedConfigLevel() throws {
        defer { fixtures.removeAll() }
        let repo = try repository()
        let configURL = fixtures.url("command-config")
        try Data("[commit]\n gpgsign = true\n[tag]\n gpgsign = false\n[user]\n signingkey = key::literal\n".utf8)
            .write(to: configURL)
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo.repo))
        defer { git_config_free(config) }
        try check(git_config_add_file_ondisk(config, configURL.path, GIT_CONFIG_LEVEL_APP, repo.repo, 0))
        let signer = Signer()
        repo.setSigner(signer)
        _ = try commit(repo)
        #expect(signer.requests.first?.key == "key::literal")
        #expect(try SigningConfig.resolve(.config, repository: repo, forTag: true) == nil)
        try check(git_config_set_bool(config, "tag.gpgsign", 1))
        #expect(try SigningConfig.resolve(.config, repository: repo, forTag: true)?.key == "key::literal")
    }

    @Test("disabled config does not interpret unrelated invalid settings")
    func disabledConfig() throws {
        defer { fixtures.removeAll() }
        let repo = try repository()
        let signer = Signer()
        repo.setSigner(signer)
        try repo.configSet("gpg.format", "invalid")
        _ = try commit(repo)
        #expect(signer.requests.isEmpty)
        try repo.configSet("commit.gpgsign", "true")
        #expect(throws: SigningError.unsupportedFormat("invalid")) { try commit(repo) }
        try repo.configSet("commit.gpgsign", "invalid")
        #expect(throws: Libgit2Error.self) { try commit(repo) }
    }

    @Test("signer runs on the caller thread without locks; errors write no commit or ref")
    func signerFailure() throws {
        defer { fixtures.removeAll() }
        let repo = try repository()
        let signer = Signer()
        let caller = Thread.current
        signer.callback = { payload, _ in
            #expect(Thread.current === caller)
            // Taking the index lock and editing config inside the callback
            // also checks that the SDK holds neither lock around sign().
            var indexLock: OpaquePointer?
            try check(gitkit_index_lock_acquire(&indexLock, repo.repo))
            gitkit_index_lock_release(indexLock)
            var headLock: OpaquePointer?
            try check(gitkit_lockfile_acquire(&headLock, fixtures.url("repo/.git/HEAD").path))
            gitkit_lockfile_release(headLock)
            try repo.configSet("test.signer", "called")
            var oid = git_oid()
            _ = try payload.withUnsafeBytes {
                try check(git_odb_hash(&oid, $0.baseAddress, $0.count, GIT_OBJECT_COMMIT))
            }
            var odb: OpaquePointer?
            try check(git_repository_odb(&odb, repo.repo))
            defer { git_odb_free(odb) }
            #expect(git_odb_exists(odb, &oid) == 0)
            throw SigningError.failed(program: "injected", stderr: "cancelled")
        }
        repo.setSigner(signer)
        #expect(throws: SigningError.failed(program: "injected", stderr: "cancelled")) {
            try commit(repo, sign: .sign(keyID: nil))
        }
        #expect(signer.requests.count == 1)
        let payload = try #require(signer.payloads.first)
        var oid = git_oid()
        _ = try payload.withUnsafeBytes {
            try check(git_odb_hash(&oid, $0.baseAddress, $0.count, GIT_OBJECT_COMMIT))
        }
        #expect(throws: Libgit2Error.self) { try repo.objectMetadata(of: repo.formatOID(&oid)) }
        #expect(throws: Libgit2Error.self) { try repo.objectMetadata(of: "HEAD") }
        #expect(!FileManager.default.fileExists(atPath: fixtures.url("repo/.git/logs/HEAD").path))
    }

    @Test("a ref moved while the signer blocks is not overwritten")
    func concurrentRefChange() throws {
        defer { fixtures.removeAll() }
        let repo = try repository()
        let initial = try commit(repo, sign: .noSign)
        let signer = Signer()
        signer.callback = { _, _ in
            let other = try Repository.open(at: #require(repo.workdirURL))
            _ = try other.commitDetailed(message: "concurrent\n", author: nil, allowEmpty: true,
                                         env: Self.environment, sign: .noSign)
            return "opaque\n"
        }
        repo.setSigner(signer)
        let error = #expect(throws: Libgit2Error.self) { try commit(repo, sign: .sign(keyID: nil)) }
        #expect(error?.code == GIT_EMODIFIED.rawValue)
        #expect(try repo.objectMetadata(of: "HEAD").sha != initial.sha)
        #expect(signer.requests.count == 1)
    }

    @Test("an unborn HEAD retargeted while the signer blocks is not updated")
    func concurrentUnbornHeadChange() throws {
        defer { fixtures.removeAll() }
        let repo = try repository()
        let signer = Signer()
        signer.callback = { _, _ in
            let other = try Repository.open(at: #require(repo.workdirURL))
            try check(git_repository_set_head(other.repo, "refs/heads/other"))
            return "opaque\n"
        }
        repo.setSigner(signer)

        let error = #expect(throws: Libgit2Error.self) { try commit(repo, sign: .sign(keyID: nil)) }

        #expect(error?.code == GIT_EMODIFIED.rawValue)
        var head: OpaquePointer?
        try check(git_reference_lookup(&head, repo.repo, "HEAD"))
        defer { git_reference_free(head) }
        #expect(git_reference_symbolic_target(head).map { String(cString: $0) } == "refs/heads/other")
        #expect(throws: Libgit2Error.self) { try repo.objectMetadata(of: "HEAD") }
        #expect(signer.requests.count == 1)
    }

    @Test("SigningError diagnostics")
    func errorMessages() {
        #expect(SigningError.missingKey.description
            == "either user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured")
        #expect(SigningError.failed(program: "gpg", stderr: "details").description
            == "gpg failed to sign the data\ndetails")
        #expect(SigningError.failed(program: "gpg", stderr: "").localizedDescription == "gpg failed to sign the data")
        #expect(SigningError.noSigner(.ssh).description == "no signer available for ssh")
        #expect(SigningError.unsupportedFormat("bad").description == "unsupported signing format 'bad'")
    }
}
