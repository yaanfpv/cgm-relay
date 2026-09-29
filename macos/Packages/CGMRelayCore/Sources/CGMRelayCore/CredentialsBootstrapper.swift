import Foundation
import Security

/// RandomBytesError names the one way SecRandomCopyBytes can fail.
public enum RandomBytesError: Error, Sendable, Equatable {
    case generationFailed(OSStatus)
}

/// RandomBytesGenerating abstracts cryptographically secure random byte
/// generation, so a test can supply fixed bytes instead of real entropy.
public protocol RandomBytesGenerating: Sendable {
    func randomBytes(count: Int) throws -> Data
}

/// SecureRandomBytesGenerator is the production RandomBytesGenerating,
/// backed by the Security framework's own CSPRNG.
public struct SecureRandomBytesGenerator: RandomBytesGenerating {
    public init() {}

    public func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw RandomBytesError.generationFailed(status)
        }
        return Data(bytes)
    }
}

/// CredentialsBootstrapper fills in the two values CGM Relay owns for
/// itself and never asks a person for: the Nightscout access token and
/// the store's encryption key. Each is generated once, only the first
/// time no value is present; an existing one is never overwritten, so
/// calling this on every launch is safe.
public struct CredentialsBootstrapper: Sendable {
    /// keySizeBytes is the length of both generated values: 32 bytes,
    /// matching the store's required AES-256 key size and giving the
    /// bearer token equivalent strength.
    public static let keySizeBytes = 32

    private let store: any CredentialStore
    private let randomBytes: any RandomBytesGenerating

    public init(store: any CredentialStore, randomBytes: any RandomBytesGenerating = SecureRandomBytesGenerator()) {
        self.store = store
        self.randomBytes = randomBytes
    }

    public func ensureBootstrapped() throws {
        if try store.string(for: .token) == nil {
            let token = try randomBytes.randomBytes(count: Self.keySizeBytes).base64URLEncodedStringWithoutPadding()
            try store.setString(token, for: .token)
        }
        if try store.string(for: .storeKey) == nil {
            let key = try randomBytes.randomBytes(count: Self.keySizeBytes).base64EncodedString()
            try store.setString(key, for: .storeKey)
        }
    }

    /// rotateToken generates and saves a fresh bearer token, in the same
    /// encoding ensureBootstrapped's own first-run token uses, and returns
    /// it. Unlike ensureBootstrapped, this always overwrites: it exists
    /// for "Make a New Token…", where overwriting the old token is the
    /// whole point -- every follower app presenting it is refused from
    /// the moment the engine restarts with the new one.
    public func rotateToken() throws -> String {
        let token = try randomBytes.randomBytes(count: Self.keySizeBytes).base64URLEncodedStringWithoutPadding()
        try store.setString(token, for: .token)
        return token
    }
}

extension Data {
    /// base64URLEncodedStringWithoutPadding renders standard base64 with
    /// `+`/`/` swapped for the URL-safe `-`/`_` and trailing `=` removed,
    /// which is what a Nightscout follower app expects in a bearer token
    /// that may appear in a URL.
    func base64URLEncodedStringWithoutPadding() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
