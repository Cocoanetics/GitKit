/// Signature formats supported by git's `gpg.format` setting.
public enum SigningFormat: String, Sendable {
    case openpgp, ssh, x509
}
