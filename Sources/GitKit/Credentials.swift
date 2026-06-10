import Foundation
import CGitKit

/// What an auth challenge is asking for. Mirrors libgit2's
/// `GIT_CREDENTIAL_*` flags. The transport may permit several at once
/// (e.g. SSH usually advertises `[.sshKey, .username, .sshAgent]`).
public struct CredentialKind: OptionSet, Sendable, Hashable {
    /// Raw `GIT_CREDENTIAL_*` bitmask exactly as libgit2 passes it to
    /// the credential callback.
    public let rawValue: UInt32
    /// Create a kind set from a raw `GIT_CREDENTIAL_*` bitmask.
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    // Clang on MSVC imports libgit2's enums with an `Int32` raw value;
    // Apple/Linux import them as `UInt32`. Funnel through `UInt32(...)`
    // so both platforms match the `OptionSet`'s `UInt32` rawValue.

    /// `GIT_CREDENTIAL_USERPASS_PLAINTEXT` — plain username+password
    /// pair; the HTTPS basic-auth flow (tokens ride it too).
    public static let userPassword = CredentialKind(rawValue: UInt32(GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue))
    /// `GIT_CREDENTIAL_SSH_KEY` — SSH key-based auth, from key files
    /// on disk or the running ssh-agent.
    public static let sshKey       = CredentialKind(rawValue: UInt32(GIT_CREDENTIAL_SSH_KEY.rawValue))
    /// `GIT_CREDENTIAL_SSH_CUSTOM` — SSH key auth with a
    /// caller-supplied signing callback (exotic key setups).
    public static let sshCustom    = CredentialKind(rawValue: UInt32(GIT_CREDENTIAL_SSH_CUSTOM.rawValue))
    /// `GIT_CREDENTIAL_DEFAULT` — "default" OS credentials for
    /// Negotiate / NTLM single sign-on.
    public static let `default`    = CredentialKind(rawValue: UInt32(GIT_CREDENTIAL_DEFAULT.rawValue))
    /// `GIT_CREDENTIAL_SSH_INTERACTIVE` — SSH keyboard-interactive
    /// challenge-response auth.
    public static let sshInteractive = CredentialKind(rawValue: UInt32(GIT_CREDENTIAL_SSH_INTERACTIVE.rawValue))
    /// `GIT_CREDENTIAL_USERNAME` — pre-auth step where the transport
    /// only wants a username (SSH URLs that don't embed one).
    public static let username     = CredentialKind(rawValue: UInt32(GIT_CREDENTIAL_USERNAME.rawValue))
    /// `GIT_CREDENTIAL_SSH_MEMORY` — SSH key auth with the key
    /// material passed as in-memory strings instead of file paths.
    public static let sshMemory    = CredentialKind(rawValue: UInt32(GIT_CREDENTIAL_SSH_MEMORY.rawValue))
}

/// What our caller hands back from a `CredentialProvider`. We translate
/// each case into the corresponding `git_credential_*` constructor at
/// the C boundary.
public enum Credentials: Sendable {
    /// HTTPS basic auth. For GitHub/GitLab token auth, prefer ``token``
    /// — it picks the right magic username for you.
    case userPassword(username: String, password: String)

    /// HTTPS bearer-token auth, encoded as basic auth with a magic
    /// username. Defaults to `x-access-token` (works for GitHub, GitLab,
    /// Bitbucket and most providers).
    case token(_ token: String, username: String = "x-access-token")

    /// SSH key files on disk. `publicKey` may be `nil` — libgit2 will
    /// derive it from the private key when omitted.
    case sshKey(username: String, publicKey: URL?, privateKey: URL, passphrase: String?)

    /// Use the running ssh-agent to authenticate `username`.
    case sshAgent(username: String)

    /// Just hand the transport a username (used when SSH asks for one
    /// up front via `GIT_CREDENTIAL_USERNAME`).
    case username(_ username: String)

    /// "Default" credentials — Negotiate / NTLM via OS facilities.
    /// Rarely useful on Apple platforms.
    case `default`
}

/// Synchronous closure invoked by the libgit2 transport whenever it
/// needs credentials. Called from a background thread libgit2 owns.
///
/// - parameter url: The URL libgit2 is connecting to.
/// - parameter usernameFromURL: Username embedded in the URL, if any
///   (e.g. `git` for `git@github.com:foo/bar.git`).
/// - parameter allowed: Auth kinds the transport will accept.
///
/// Return `nil` to abort with `GIT_EUSER` — libgit2 will surface this as
/// an authentication error to your `try await` site.
public typealias CredentialProvider = @Sendable (
    _ url: URL,
    _ usernameFromURL: String?,
    _ allowed: CredentialKind
) -> Credentials?

/// Ready-made `CredentialProvider`s for the common cases.
public enum CredentialProviders {
    /// Always hands back a userpass-token credential when the transport
    /// asks for one. Returns `nil` for SSH / username-only challenges so
    /// libgit2 surfaces a clean auth error instead of looping.
    public static func token(_ token: String, username: String = "x-access-token") -> CredentialProvider {
        return { _, _, allowed in
            guard allowed.contains(.userPassword) else { return nil }
            return .token(token, username: username)
        }
    }
}
