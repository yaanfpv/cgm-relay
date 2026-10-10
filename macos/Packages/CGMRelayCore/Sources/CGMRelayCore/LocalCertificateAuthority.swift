import Crypto
import Foundation
import SwiftASN1
import X509

/// LocalCertificateMaterial is what the app needs to serve HTTPS to a phone
/// on the same network: the authority certificate the phone installs and
/// trusts, and the server certificate and key the relay presents.
public struct LocalCertificateMaterial: Sendable, Equatable {
    /// AuthorityChange says what happened to the authority during the call
    /// that produced this material. Every phone trusts one authority
    /// certificate, so anything but `unchanged` means the certificate has to
    /// be installed on the phone (again).
    public enum AuthorityChange: Sendable, Equatable {
        /// The authority already existed and still fits the name.
        case unchanged
        /// There was no authority before this call.
        case created
        /// An earlier authority existed but could not be kept, so phones that
        /// trusted it must install the new certificate. The reason says why.
        case replaced(ReplacementReason)
    }

    /// ReplacementReason is why an earlier authority was not kept.
    public enum ReplacementReason: Sendable, Equatable {
        /// It was whole and still valid, but made for another `.local` name:
        /// this Mac's name changed.
        case renamed
        /// It was whole but past its end date.
        case expired
        /// It could not be read or did not fit together: a key missing,
        /// malformed or not matching the certificate, or a certificate
        /// missing, malformed or not made the way CGM Relay makes one.
        case unusable
    }

    public let authorityCertificateDER: Data
    public let authorityCertificatePEM: String
    public let serverCertificatePEM: String
    public let serverKeyPEM: String
    public let authorityChange: AuthorityChange

    /// phonesMustInstallCertificate is true when the phone has nothing to
    /// trust yet or trusts an authority that is gone.
    public var phonesMustInstallCertificate: Bool {
        authorityChange != .unchanged
    }
}

/// LocalCertificateError names the inputs a certificate can not be made for.
public enum LocalCertificateError: Error, Sendable, Equatable {
    case invalidName(String)
    case invalidAddress(String)
}

/// LocalCertificateAuthority keeps CGM Relay's own small certificate
/// authority and one server certificate for this Mac, so a phone on the same
/// Wi-Fi can reach the relay over HTTPS without a public certificate.
///
/// The authority is limited to the one `.local` name it was made for and to
/// the private IPv4 ranges, so a phone that trusts it trusts it for nothing
/// else. It is tied to that name: when the name changes, the old authority is
/// never widened or reused; a new authority and server certificate replace
/// it. Both private keys and both certificates live in the credential store
/// (the Keychain in production) and nowhere else.
public final class LocalCertificateAuthority: @unchecked Sendable {
    static let day: TimeInterval = 86_400
    static let authorityLifetime = 3650 * day
    static let serverLifetime = 825 * day
    static let renewalWindow = 30 * day
    /// backdating starts a certificate's validity slightly in the past, so a
    /// phone whose clock runs a little behind still accepts it.
    static let backdating: TimeInterval = 3600

    private let store: any CredentialStore
    private let lock = NSLock()

    public init(store: any CredentialStore) {
        self.store = store
    }

    /// currentMaterial returns the authority and server certificate for name
    /// (this Mac's `.local` host name) and ipv4s (its private IPv4 addresses),
    /// making or re-issuing whatever is missing or no longer fits: the server
    /// certificate when it is within 30 days of expiry or the addresses
    /// changed, the authority when it is missing, unusable or made for another
    /// name. Nothing is written when the stored material already fits.
    public func currentMaterial(name: String, ipv4s: [String]) throws -> LocalCertificateMaterial {
        let host = try Self.normalizedName(name)
        let addresses = try Self.normalizedAddresses(ipv4s)
        return try lock.withLock {
            let now = Date()
            let stored = try storedValues()

            var change = LocalCertificateMaterial.AuthorityChange.unchanged
            var writes: [CredentialKey: String] = [:]

            let authority: Authority
            if let kept = Self.keptAuthority(stored, host: host, now: now) {
                authority = kept
            } else {
                authority = try Self.makeAuthority(host: host, now: now)
                change = stored[.authorityKey] == nil && stored[.authorityCertificate] == nil
                    ? .created
                    : .replaced(Self.replacementReason(stored, host: host, now: now))
                writes[.authorityKey] = authority.key.pemRepresentation
                writes[.authorityCertificate] = try authority.certificate.serializeAsPEM().pemString
            }

            let server: Server
            if change == .unchanged,
                let kept = Self.keptServer(stored, authority: authority, host: host, addresses: addresses, now: now)
            {
                server = kept
            } else {
                server = try Self.makeServer(authority: authority, host: host, addresses: addresses, now: now)
                writes[.serverKey] = server.key.pemRepresentation
                writes[.serverCertificate] = try server.certificate.serializeAsPEM().pemString
            }

            if !writes.isEmpty {
                try store.setStrings(writes)
            }

            let authorityPEM = try authority.certificate.serializeAsPEM()
            return LocalCertificateMaterial(
                authorityCertificateDER: Data(authorityPEM.derBytes),
                authorityCertificatePEM: authorityPEM.pemString,
                serverCertificatePEM: try server.certificate.serializeAsPEM().pemString,
                serverKeyPEM: server.key.pemRepresentation,
                authorityChange: change
            )
        }
    }

    // MARK: Stored material

    private func storedValues() throws -> [CredentialKey: String] {
        var values: [CredentialKey: String] = [:]
        for key in [CredentialKey.authorityKey, .authorityCertificate, .serverKey, .serverCertificate] {
            values[key] = try store.string(for: key)
        }
        return values
    }

    private struct Authority {
        let key: P256.Signing.PrivateKey
        let certificate: Certificate
    }

    private struct Server {
        let key: P256.Signing.PrivateKey
        let certificate: Certificate
    }

    /// keptAuthority returns the stored authority only when it is whole and
    /// still right: its key matches its certificate, its name and constraints
    /// are exactly the ones CGM Relay gives an authority for host, and it has
    /// not expired. Anything else is treated as absent, never repaired.
    private static func keptAuthority(_ stored: [CredentialKey: String], host: String, now: Date) -> Authority? {
        guard let keyPEM = stored[.authorityKey],
            let certificatePEM = stored[.authorityCertificate],
            let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM),
            let certificate = try? Certificate(pemEncoded: certificatePEM),
            certificate.publicKey == Certificate.PublicKey(key.publicKey),
            let nameConstraints = try? certificate.extensions.nameConstraints,
            nameConstraints == authorityNameConstraints(host: host),
            let subject = try? authoritySubject(host: host),
            certificate.subject == subject,
            certificate.notValidAfter > now
        else { return nil }
        return Authority(key: key, certificate: certificate)
    }

    /// replacementReason says why a stored authority that keptAuthority
    /// refused was not kept. Only an authority that is whole, unexpired and
    /// made exactly as CGM Relay makes one for a different `.local` name counts
    /// as a rename.
    private static func replacementReason(_ stored: [CredentialKey: String], host: String, now: Date) -> LocalCertificateMaterial.ReplacementReason {
        guard let keyPEM = stored[.authorityKey],
            let certificatePEM = stored[.authorityCertificate],
            let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM),
            let certificate = try? Certificate(pemEncoded: certificatePEM),
            certificate.publicKey == Certificate.PublicKey(key.publicKey),
            let nameConstraints = try? certificate.extensions.nameConstraints,
            let earlierHost = nameConstraints.permittedDNSDomains.first,
            nameConstraints == authorityNameConstraints(host: earlierHost),
            let earlierSubject = try? authoritySubject(host: earlierHost),
            certificate.subject == earlierSubject
        else { return .unusable }
        if certificate.notValidAfter <= now { return .expired }
        return earlierHost == host ? .unusable : .renamed
    }

    /// keptServer returns the stored server certificate only when it is
    /// whole, issued by authority, names exactly host and addresses, ends no
    /// later than authority, and has more than the renewal window left (a
    /// certificate already ending with its authority can not be extended, so
    /// it is kept until the authority itself is replaced).
    private static func keptServer(
        _ stored: [CredentialKey: String],
        authority: Authority,
        host: String,
        addresses: [String],
        now: Date
    ) -> Server? {
        guard let keyPEM = stored[.serverKey],
            let certificatePEM = stored[.serverCertificate],
            let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM),
            let certificate = try? Certificate(pemEncoded: certificatePEM),
            certificate.publicKey == Certificate.PublicKey(key.publicKey),
            certificate.issuer == authority.certificate.subject,
            authority.certificate.publicKey.isValidSignature(certificate.signature, for: certificate),
            let names = try? certificate.extensions.subjectAlternativeNames,
            Set(names) == Set(serverNames(host: host, addresses: addresses)),
            certificate.notValidAfter <= authority.certificate.notValidAfter,
            certificate.notValidAfter.timeIntervalSince(now) > renewalWindow
                || certificate.notValidAfter == authority.certificate.notValidAfter
        else { return nil }
        return Server(key: key, certificate: certificate)
    }

    // MARK: Issuing

    private static func makeAuthority(host: String, now: Date) throws -> Authority {
        let key = P256.Signing.PrivateKey()
        let notBefore = whole(now - backdating)
        let certificate = try issueAuthorityCertificate(
            key: key,
            host: host,
            notBefore: notBefore,
            notAfter: notBefore.addingTimeInterval(authorityLifetime)
        )
        return Authority(key: key, certificate: certificate)
    }

    private static func makeServer(authority: Authority, host: String, addresses: [String], now: Date) throws -> Server {
        let key = P256.Signing.PrivateKey()
        let notBefore = whole(now - backdating)
        let certificate = try issueServerCertificate(
            key: key.publicKey,
            authorityKey: authority.key,
            authorityCertificate: authority.certificate,
            host: host,
            addresses: addresses,
            notBefore: notBefore,
            notAfter: min(notBefore.addingTimeInterval(serverLifetime), authority.certificate.notValidAfter)
        )
        return Server(key: key, certificate: certificate)
    }

    /// issueAuthorityCertificate signs a self-issued authority certificate
    /// with the given validity. The validity is a parameter so tests can make
    /// certificates at the edges of the renewal window.
    static func issueAuthorityCertificate(
        key: P256.Signing.PrivateKey,
        host: String,
        notBefore: Date,
        notAfter: Date
    ) throws -> Certificate {
        let subject = try authoritySubject(host: host)
        let publicKey = Certificate.PublicKey(key.publicKey)
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                Critical(authorityNameConstraints(host: host))
                SubjectKeyIdentifier(keyIdentifier: keyIdentifier(for: key.publicKey))
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
    }

    /// authoritySubject is the name an authority made for host carries.
    static func authoritySubject(host: String) throws -> DistinguishedName {
        try DistinguishedName {
            OrganizationName("CGM Relay")
            CommonName("CGM Relay on \(host)")
        }
    }

    /// issueServerCertificate signs a server certificate for host and
    /// addresses under the authority, with the given validity.
    static func issueServerCertificate(
        key: P256.Signing.PublicKey,
        authorityKey: P256.Signing.PrivateKey,
        authorityCertificate: Certificate,
        host: String,
        addresses: [String],
        notBefore: Date,
        notAfter: Date
    ) throws -> Certificate {
        let subject = try DistinguishedName {
            CommonName(host)
        }
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key),
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: authorityCertificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(serverNames(host: host, addresses: addresses))
                SubjectKeyIdentifier(keyIdentifier: keyIdentifier(for: key))
                AuthorityKeyIdentifier(keyIdentifier: keyIdentifier(for: authorityKey.publicKey))
            },
            issuerPrivateKey: Certificate.PrivateKey(authorityKey)
        )
    }

    /// authorityNameConstraints permits exactly host and the three private
    /// IPv4 ranges; any other name is outside what the authority may vouch for.
    static func authorityNameConstraints(host: String) -> NameConstraints {
        NameConstraints(
            permittedDNSDomains: [host],
            permittedIPRanges: privateRanges.map { ASN1OctetString(contentBytes: ArraySlice($0.address + $0.mask)) }
        )
    }

    static func serverNames(host: String, addresses: [String]) -> [GeneralName] {
        [.dnsName(host)] + addresses.map { address in
            .ipAddress(ASN1OctetString(contentBytes: ArraySlice(address.split(separator: ".").map { UInt8($0)! })))
        }
    }

    private static let privateRanges: [(address: [UInt8], mask: [UInt8])] = [
        ([10, 0, 0, 0], [255, 0, 0, 0]),
        ([172, 16, 0, 0], [255, 240, 0, 0]),
        ([192, 168, 0, 0], [255, 255, 0, 0]),
    ]

    /// keyIdentifier is the SHA-1 of the public key point, the usual way to
    /// name a key so a verifier can match a certificate to its issuer.
    private static func keyIdentifier(for key: P256.Signing.PublicKey) -> ArraySlice<UInt8> {
        ArraySlice(Insecure.SHA1.hash(data: key.x963Representation))
    }

    /// whole drops the sub-second part, which a certificate's time fields
    /// can not hold, so the lifetimes read back exactly.
    static func whole(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    // MARK: Input checks

    /// normalizedName lowercases name and requires `<host>.local` with
    /// ordinary host name labels, since the name becomes a DNS name
    /// constraint and a certificate name.
    static func normalizedName(_ name: String) throws -> String {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        let suffix = ".local"
        guard lowered.hasSuffix(suffix), lowered.count > suffix.count else {
            throw LocalCertificateError.invalidName(name)
        }
        let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        let validLabel: (Substring) -> Bool = { label in
            !label.isEmpty && label.count <= 63
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        guard labels.allSatisfy(validLabel) else {
            throw LocalCertificateError.invalidName(name)
        }
        return lowered
    }

    /// normalizedAddresses requires dotted-quad IPv4 addresses inside the
    /// private ranges and returns them without duplicates, in a fixed order.
    static func normalizedAddresses(_ addresses: [String]) throws -> [String] {
        var unique = Set<String>()
        for address in addresses {
            let parts = address.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4,
                parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCIIDigit) && ($0 == "0" || !$0.hasPrefix("0")) }),
                let octets = Optional(parts.compactMap { UInt8($0) }), octets.count == 4,
                privateRanges.contains(where: { range in
                    zip(octets, zip(range.address, range.mask)).allSatisfy { $0 & $1.1 == $1.0 }
                })
            else {
                throw LocalCertificateError.invalidAddress(address)
            }
            unique.insert(octets.map(String.init).joined(separator: "."))
        }
        return unique.sorted()
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
