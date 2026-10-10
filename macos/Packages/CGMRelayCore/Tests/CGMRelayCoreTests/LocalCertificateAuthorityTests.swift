import Crypto
import Foundation
import Security
import SwiftASN1
import Testing
import X509
@testable import CGMRelayCore

/// Certificates here are decoded and checked with swift-certificates' own
/// parser and verifier and with Security's trust evaluation, never with the
/// code that issued them, so a field the issuer gets wrong is not read back
/// through the same mistake.
@Suite("LocalCertificateAuthority")
struct LocalCertificateAuthorityTests {
    private static let host = "relay-test.local"
    private static let day = LocalCertificateAuthority.day

    // MARK: Certificate contents

    @Test("the authority certificate carries exactly the agreed fields")
    func authorityFields() throws {
        let material = try LocalCertificateAuthority(store: FakeCredentialStore())
            .currentMaterial(name: Self.host, ipv4s: ["192.168.1.20"])
        let authority = try Certificate(derEncoded: Array(material.authorityCertificateDER))

        #expect(P256.Signing.PublicKey(authority.publicKey) != nil)
        #expect(authority.signatureAlgorithm == .ecdsaWithSHA256)
        #expect(authority.subject == authority.issuer)
        #expect(authority.publicKey.isValidSignature(authority.signature, for: authority))
        #expect(authority.notValidAfter.timeIntervalSince(authority.notValidBefore) == 3650 * Self.day)

        let basic = try #require(authority.extensions[oid: .X509ExtensionID.basicConstraints])
        #expect(basic.critical)
        #expect(try BasicConstraints(basic) == .isCertificateAuthority(maxPathLength: 0))

        let usage = try #require(authority.extensions[oid: .X509ExtensionID.keyUsage])
        #expect(usage.critical)
        #expect(try KeyUsage(usage) == KeyUsage(keyCertSign: true, cRLSign: true))

        let constraints = try #require(authority.extensions[oid: .X509ExtensionID.nameConstraints])
        #expect(constraints.critical)
        let decoded = try NameConstraints(constraints)
        #expect(decoded.excludedSubtrees.isEmpty)
        #expect(decoded.permittedSubtrees.count == 4)
        #expect(Array(decoded.permittedDNSDomains) == [Self.host])
        #expect(
            Set(decoded.permittedIPRanges.map { Array($0.bytes) }) == [
                [10, 0, 0, 0, 255, 0, 0, 0],
                [172, 16, 0, 0, 255, 240, 0, 0],
                [192, 168, 0, 0, 255, 255, 0, 0],
            ]
        )
    }

    @Test("the server certificate carries exactly the agreed fields and chains to the authority")
    func serverFields() throws {
        let material = try LocalCertificateAuthority(store: FakeCredentialStore())
            .currentMaterial(name: Self.host, ipv4s: ["192.168.1.20", "10.0.0.7"])
        let authority = try Certificate(derEncoded: Array(material.authorityCertificateDER))
        let server = try Certificate(pemEncoded: material.serverCertificatePEM)

        #expect(P256.Signing.PublicKey(server.publicKey) != nil)
        #expect(server.signatureAlgorithm == .ecdsaWithSHA256)
        #expect(server.issuer == authority.subject)
        #expect(authority.publicKey.isValidSignature(server.signature, for: server))
        #expect(server.notValidAfter.timeIntervalSince(server.notValidBefore) == 825 * Self.day)

        let basic = try #require(server.extensions[oid: .X509ExtensionID.basicConstraints])
        #expect(try BasicConstraints(basic) == .notCertificateAuthority)

        let usage = try #require(server.extensions[oid: .X509ExtensionID.keyUsage])
        #expect(usage.critical)
        #expect(try KeyUsage(usage) == KeyUsage(digitalSignature: true))

        let eku = try #require(server.extensions[oid: .X509ExtensionID.extendedKeyUsage])
        #expect(try Array(ExtendedKeyUsage(eku)) == [.serverAuth])

        let names = try #require(try server.extensions.subjectAlternativeNames)
        #expect(
            Set(names) == [
                .dnsName(Self.host),
                .ipAddress(ASN1OctetString(contentBytes: [192, 168, 1, 20])),
                .ipAddress(ASN1OctetString(contentBytes: [10, 0, 0, 7])),
            ]
        )
        #expect(names.count == 3)
    }

    @Test("the returned key and PEM forms describe the certificates they accompany")
    func pemFormsAgree() throws {
        let material = try LocalCertificateAuthority(store: FakeCredentialStore())
            .currentMaterial(name: Self.host, ipv4s: [])
        let authority = try Certificate(derEncoded: Array(material.authorityCertificateDER))
        #expect(try Certificate(pemEncoded: material.authorityCertificatePEM) == authority)

        let server = try Certificate(pemEncoded: material.serverCertificatePEM)
        let key = try P256.Signing.PrivateKey(pemRepresentation: material.serverKeyPEM)
        #expect(server.publicKey == Certificate.PublicKey(key.publicKey))
    }

    @Test("a verifier that trusts only the authority accepts the server certificate for its name and addresses")
    func chainValidates() async throws {
        let material = try LocalCertificateAuthority(store: FakeCredentialStore())
            .currentMaterial(name: Self.host, ipv4s: ["192.168.1.20"])
        let authority = try Certificate(derEncoded: Array(material.authorityCertificateDER))
        let server = try Certificate(pemEncoded: material.serverCertificatePEM)

        for identity in [(Self.host, nil), (nil, "192.168.1.20")] as [(String?, String?)] {
            var verifier = Verifier(rootCertificates: CertificateStore([authority])) {
                RFC5280Policy()
                ServerIdentityPolicy(serverHostname: identity.0, serverIP: identity.1)
            }
            let result = await verifier.validate(leaf: server, intermediates: CertificateStore())
            #expect(result.isValidCertificate)
        }
    }

    @Test("the operating system's trust evaluation accepts the server certificate once the authority is trusted")
    func systemTrustAccepts() throws {
        let material = try LocalCertificateAuthority(store: FakeCredentialStore())
            .currentMaterial(name: Self.host, ipv4s: ["192.168.1.20"])
        let authority = try #require(SecCertificateCreateWithData(nil, material.authorityCertificateDER as CFData))
        let leafDER = try Certificate(pemEncoded: material.serverCertificatePEM).serializeAsPEM().derBytes
        let server = try #require(SecCertificateCreateWithData(nil, Data(leafDER) as CFData))

        for hostname in [Self.host, "192.168.1.20"] {
            var trust: SecTrust?
            #expect(SecTrustCreateWithCertificates(server, SecPolicyCreateSSL(true, hostname as CFString), &trust) == errSecSuccess)
            let evaluated = try #require(trust)
            SecTrustSetAnchorCertificates(evaluated, [authority] as CFArray)
            SecTrustSetAnchorCertificatesOnly(evaluated, true)
            var error: CFError?
            #expect(SecTrustEvaluateWithError(evaluated, &error), "\(hostname): \(String(describing: error))")
        }
    }

    // MARK: Inputs

    @Test("a name that is not a .local host name is refused")
    func refusesBadNames() {
        let authority = LocalCertificateAuthority(store: FakeCredentialStore())
        for name in ["", "relay", ".local", "relay.example.com", "re lay.local", "-relay.local", "relay..local", "relay.local.evil.com"] {
            #expect(throws: LocalCertificateError.invalidName(name)) {
                try authority.currentMaterial(name: name, ipv4s: [])
            }
        }
    }

    @Test("an address outside the private IPv4 ranges is refused, and equivalent address lists give one certificate")
    func addressChecks() throws {
        let authority = LocalCertificateAuthority(store: FakeCredentialStore())
        for address in ["8.8.8.8", "172.32.0.1", "172.15.255.255", "192.169.0.1", "192.168.1", "192.168.1.256", "192.168.01.1", "fe80::1", "+192.168.1.1", "192.168.1.1/24"] {
            #expect(throws: LocalCertificateError.invalidAddress(address)) {
                try authority.currentMaterial(name: Self.host, ipv4s: [address])
            }
        }

        let first = try authority.currentMaterial(name: Self.host, ipv4s: ["172.31.255.254", "10.0.0.7"])
        let reordered = try authority.currentMaterial(name: "RELAY-test.local", ipv4s: ["10.0.0.7", "172.31.255.254", "10.0.0.7"])
        #expect(reordered.serverCertificatePEM == first.serverCertificatePEM)
        #expect(reordered.authorityChange == .unchanged)
    }

    // MARK: Renewal

    @Test("a server certificate with more than 30 days left is kept and one at 30 days is re-issued under the same authority")
    func renewalWindow() throws {
        let store = FakeCredentialStore()
        let authority = LocalCertificateAuthority(store: store)
        let addresses = ["192.168.1.20"]
        let first = try authority.currentMaterial(name: Self.host, ipv4s: addresses)
        let authorityKey = try P256.Signing.PrivateKey(pemRepresentation: try #require(store.snapshot()[.authorityKey]))
        let authorityCertificate = try Certificate(pemEncoded: first.authorityCertificatePEM)

        let outside = try Self.storeServerFixture(
            in: store, authorityKey: authorityKey, authorityCertificate: authorityCertificate,
            addresses: addresses, expiresIn: 30 * Self.day + 3600)
        let kept = try authority.currentMaterial(name: Self.host, ipv4s: addresses)
        #expect(kept.serverCertificatePEM == outside)
        #expect(kept.authorityCertificateDER == first.authorityCertificateDER)
        #expect(kept.authorityChange == .unchanged)

        let atWindow = try Self.storeServerFixture(
            in: store, authorityKey: authorityKey, authorityCertificate: authorityCertificate,
            addresses: addresses, expiresIn: 30 * Self.day)
        let renewed = try authority.currentMaterial(name: Self.host, ipv4s: addresses)
        #expect(renewed.serverCertificatePEM != atWindow)
        #expect(renewed.authorityCertificateDER == first.authorityCertificateDER)
        #expect(renewed.authorityChange == .unchanged)
        let server = try Certificate(pemEncoded: renewed.serverCertificatePEM)
        #expect(server.notValidAfter.timeIntervalSinceNow > 800 * Self.day)
        let issuer = try Certificate(derEncoded: Array(renewed.authorityCertificateDER))
        #expect(issuer.publicKey.isValidSignature(server.signature, for: server))

        // Near the end of the authority's own life the new certificate stops
        // with it, is then kept, and a stored one that outlives it is replaced.
        let agingStore = FakeCredentialStore()
        let agingKey = P256.Signing.PrivateKey()
        let agingEnd = LocalCertificateAuthority.whole(Date().addingTimeInterval(100 * Self.day))
        let agingAuthority = try LocalCertificateAuthority.issueAuthorityCertificate(
            key: agingKey, host: Self.host, notBefore: LocalCertificateAuthority.whole(Date() - 3600), notAfter: agingEnd)
        try agingStore.setStrings([
            .authorityKey: agingKey.pemRepresentation,
            .authorityCertificate: try agingAuthority.serializeAsPEM().pemString,
        ])
        let aging = LocalCertificateAuthority(store: agingStore)
        let clamped = try aging.currentMaterial(name: Self.host, ipv4s: addresses)
        #expect(try Certificate(pemEncoded: clamped.serverCertificatePEM).notValidAfter == agingEnd)
        #expect(try aging.currentMaterial(name: Self.host, ipv4s: addresses).serverCertificatePEM == clamped.serverCertificatePEM)

        let outliving = try Self.storeServerFixture(
            in: agingStore, authorityKey: agingKey, authorityCertificate: agingAuthority,
            addresses: addresses, expiresIn: 400 * Self.day)
        let replaced = try aging.currentMaterial(name: Self.host, ipv4s: addresses)
        #expect(replaced.serverCertificatePEM != outliving)
        #expect(try Certificate(pemEncoded: replaced.serverCertificatePEM).notValidAfter <= agingEnd)
    }

    @Test("a server certificate that no longer chains to the stored authority is re-issued")
    func foreignServerCertificateIsReplaced() throws {
        let store = FakeCredentialStore()
        let authority = LocalCertificateAuthority(store: store)
        let first = try authority.currentMaterial(name: Self.host, ipv4s: [])

        let otherKey = P256.Signing.PrivateKey()
        let otherCertificate = try LocalCertificateAuthority.issueAuthorityCertificate(
            key: otherKey, host: Self.host,
            notBefore: Date(timeIntervalSinceNow: -3600), notAfter: Date(timeIntervalSinceNow: 100 * Self.day))
        let foreign = try Self.storeServerFixture(
            in: store, authorityKey: otherKey, authorityCertificate: otherCertificate,
            addresses: [], expiresIn: 400 * Self.day)

        let result = try authority.currentMaterial(name: Self.host, ipv4s: [])
        #expect(result.serverCertificatePEM != foreign)
        #expect(result.authorityCertificateDER == first.authorityCertificateDER)
        let server = try Certificate(pemEncoded: result.serverCertificatePEM)
        let issuer = try Certificate(derEncoded: Array(result.authorityCertificateDER))
        #expect(issuer.publicKey.isValidSignature(server.signature, for: server))
    }

    @Test("when the private IPv4 addresses change the server certificate is re-issued under the same authority")
    func addressChangeReissues() throws {
        let authority = LocalCertificateAuthority(store: FakeCredentialStore())
        let first = try authority.currentMaterial(name: Self.host, ipv4s: ["192.168.1.20"])
        let second = try authority.currentMaterial(name: Self.host, ipv4s: ["192.168.1.20", "10.1.2.3"])

        #expect(second.serverCertificatePEM != first.serverCertificatePEM)
        #expect(second.authorityCertificateDER == first.authorityCertificateDER)
        #expect(second.authorityChange == .unchanged)
        #expect(!second.phonesMustInstallCertificate)
        let secondNames = try #require(try Certificate(pemEncoded: second.serverCertificatePEM).extensions.subjectAlternativeNames)
        #expect(
            Set(secondNames) == [
                .dnsName(Self.host),
                .ipAddress(ASN1OctetString(contentBytes: [192, 168, 1, 20])),
                .ipAddress(ASN1OctetString(contentBytes: [10, 1, 2, 3])),
            ]
        )

        let third = try authority.currentMaterial(name: Self.host, ipv4s: [])
        let thirdNames = try #require(try Certificate(pemEncoded: third.serverCertificatePEM).extensions.subjectAlternativeNames)
        #expect(Set(thirdNames) == [.dnsName(Self.host)])
    }

    // MARK: Name change

    @Test("the first call makes an authority and an unchanged name keeps it, writing nothing")
    func firstCallThenSteady() throws {
        let store = FakeCredentialStore()
        let authority = LocalCertificateAuthority(store: store)
        let first = try authority.currentMaterial(name: Self.host, ipv4s: ["192.168.1.20"])
        #expect(first.authorityChange == .created)
        #expect(first.phonesMustInstallCertificate)

        let stored = store.snapshot()
        let again = try authority.currentMaterial(name: Self.host, ipv4s: ["192.168.1.20"])
        #expect(again == LocalCertificateMaterial(
            authorityCertificateDER: first.authorityCertificateDER,
            authorityCertificatePEM: first.authorityCertificatePEM,
            serverCertificatePEM: first.serverCertificatePEM,
            serverKeyPEM: first.serverKeyPEM,
            authorityChange: .unchanged))
        #expect(store.snapshot() == stored)
    }

    @Test("a new name gets a new authority that holds only that name, and the old authority can not vouch for it")
    func nameChangeReplacesAuthority() async throws {
        let store = FakeCredentialStore()
        let authority = LocalCertificateAuthority(store: store)
        let oldHost = "old-mac.local"
        let newHost = "new-mac.local"

        let old = try authority.currentMaterial(name: oldHost, ipv4s: ["192.168.1.20"])
        let oldKey = try P256.Signing.PrivateKey(pemRepresentation: try #require(store.snapshot()[.authorityKey]))
        let oldAuthority = try Certificate(derEncoded: Array(old.authorityCertificateDER))

        let renamed = try authority.currentMaterial(name: newHost, ipv4s: ["192.168.1.20"])
        #expect(renamed.authorityChange == .replaced(.renamed))
        #expect(renamed.phonesMustInstallCertificate)
        #expect(renamed.authorityCertificateDER != old.authorityCertificateDER)

        let newAuthority = try Certificate(derEncoded: Array(renamed.authorityCertificateDER))
        #expect(newAuthority.publicKey != oldAuthority.publicKey)
        let constraints = try NameConstraints(try #require(newAuthority.extensions[oid: .X509ExtensionID.nameConstraints]))
        #expect(Array(constraints.permittedDNSDomains) == [newHost])

        let newServer = try Certificate(pemEncoded: renamed.serverCertificatePEM)
        #expect(newAuthority.publicKey.isValidSignature(newServer.signature, for: newServer))
        #expect(!oldAuthority.publicKey.isValidSignature(newServer.signature, for: newServer))
        let newNames = try #require(try newServer.extensions.subjectAlternativeNames)
        #expect(Set(newNames) == [.dnsName(newHost), .ipAddress(ASN1OctetString(contentBytes: [192, 168, 1, 20]))])

        // Even a leaf for the new name signed with the old authority's own key
        // is refused through the old authority's name constraint, while the
        // same authority does vouch for its own name.
        let now = Date()
        let forNewName = try LocalCertificateAuthority.issueServerCertificate(
            key: P256.Signing.PrivateKey().publicKey, authorityKey: oldKey, authorityCertificate: oldAuthority,
            host: newHost, addresses: [], notBefore: now - 3600, notAfter: now + 100 * Self.day)
        let forOldName = try LocalCertificateAuthority.issueServerCertificate(
            key: P256.Signing.PrivateKey().publicKey, authorityKey: oldKey, authorityCertificate: oldAuthority,
            host: oldHost, addresses: [], notBefore: now - 3600, notAfter: now + 100 * Self.day)
        var verifier = Verifier(rootCertificates: CertificateStore([oldAuthority])) {
            RFC5280Policy()
        }
        #expect(await verifier.validate(leaf: forOldName, intermediates: CertificateStore()).isValidCertificate)
        #expect(!(await verifier.validate(leaf: forNewName, intermediates: CertificateStore()).isValidCertificate))
    }

    @Test("an authority whose key does not match its certificate is replaced and reported")
    func mismatchedAuthorityIsReplaced() throws {
        let store = FakeCredentialStore()
        let authority = LocalCertificateAuthority(store: store)
        let first = try authority.currentMaterial(name: Self.host, ipv4s: [])
        try store.setString(P256.Signing.PrivateKey().pemRepresentation, for: .authorityKey)

        let second = try authority.currentMaterial(name: Self.host, ipv4s: [])
        #expect(second.authorityChange == .replaced(.unusable), "the name did not change, so it is not reported as a rename")
        #expect(second.authorityCertificateDER != first.authorityCertificateDER)
    }

    @Test("an authority replaced while the name stayed the same is never reported as a rename")
    func replacementReasonsUnderTheSameName() throws {
        let now = Date()
        let expiredKey = P256.Signing.PrivateKey()
        let expired = try LocalCertificateAuthority.issueAuthorityCertificate(
            key: expiredKey, host: Self.host,
            notBefore: LocalCertificateAuthority.whole(now - 20 * Self.day), notAfter: LocalCertificateAuthority.whole(now - Self.day))
        let foreignKey = P256.Signing.PrivateKey()
        let foreign = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PublicKey(foreignKey.publicKey),
            notValidBefore: now - 3600, notValidAfter: now + 100 * Self.day,
            issuer: try DistinguishedName { CommonName("Someone Else") }, subject: try DistinguishedName { CommonName("Someone Else") },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(LocalCertificateAuthority.authorityNameConstraints(host: Self.host))
            },
            issuerPrivateKey: Certificate.PrivateKey(foreignKey))

        let cases: [(String, [CredentialKey: String?], LocalCertificateMaterial.ReplacementReason)] = [
            ("expired", [.authorityKey: expiredKey.pemRepresentation, .authorityCertificate: try expired.serializeAsPEM().pemString], .expired),
            ("missing key", [.authorityKey: nil], .unusable),
            ("missing certificate", [.authorityCertificate: nil], .unusable),
            ("malformed certificate", [.authorityCertificate: "-----BEGIN CERTIFICATE-----\nnot a certificate\n-----END CERTIFICATE-----\n"], .unusable),
            ("malformed key", [.authorityKey: "not a key"], .unusable),
            ("foreign authority", [.authorityKey: foreignKey.pemRepresentation, .authorityCertificate: try foreign.serializeAsPEM().pemString], .unusable),
        ]
        for (label, overrides, reason) in cases {
            let store = FakeCredentialStore()
            let authority = LocalCertificateAuthority(store: store)
            _ = try authority.currentMaterial(name: Self.host, ipv4s: [])
            for (key, value) in overrides {
                if let value { try store.setString(value, for: key) } else { try store.removeAll([key]) }
            }
            let replaced = try authority.currentMaterial(name: Self.host, ipv4s: [])
            #expect(replaced.authorityChange == .replaced(reason), "\(label)")
        }
    }

    @Test("a failed write leaves the stored authority and server certificate as they were")
    func failedWriteChangesNothing() throws {
        let store = FakeCredentialStore()
        let authority = LocalCertificateAuthority(store: store)
        _ = try authority.currentMaterial(name: Self.host, ipv4s: [])
        let stored = store.snapshot()

        store.failNextSetStrings = true
        #expect(throws: FakeCredentialStoreError.simulatedFailure) {
            try authority.currentMaterial(name: "other.local", ipv4s: [])
        }
        #expect(store.snapshot() == stored)
    }

    // MARK: Fixtures

    /// storeServerFixture stores a server certificate (with a fresh key)
    /// that expires expiresIn seconds from now, and returns its PEM.
    private static func storeServerFixture(
        in store: FakeCredentialStore,
        authorityKey: P256.Signing.PrivateKey,
        authorityCertificate: Certificate,
        addresses: [String],
        expiresIn: TimeInterval
    ) throws -> String {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        let certificate = try LocalCertificateAuthority.issueServerCertificate(
            key: key.publicKey, authorityKey: authorityKey, authorityCertificate: authorityCertificate,
            host: host, addresses: try LocalCertificateAuthority.normalizedAddresses(addresses),
            notBefore: LocalCertificateAuthority.whole(now - 3600), notAfter: LocalCertificateAuthority.whole(now + expiresIn))
        let pem = try certificate.serializeAsPEM().pemString
        try store.setStrings([.serverKey: key.pemRepresentation, .serverCertificate: pem])
        return pem
    }
}

extension CertificateValidationResult {
    fileprivate var isValidCertificate: Bool {
        if case .validCertificate = self { return true }
        return false
    }
}

/// The authority's private key must exist only in the Keychain. These tests
/// run the real Keychain store under a throwaway service and look for every
/// encoding of each authority key in everything the module could have left
/// behind: files written to the temporary directory while it ran, user
/// defaults, standard output and error, the process arguments and
/// environment, and the material it hands back.
@Suite("LocalCertificateAuthority key secrecy", .serialized)
struct LocalCertificateAuthoritySecrecyTests {
    /// AttemptRecordingStore passes everything to a real store but remembers
    /// every value it was asked to write, and can refuse the writes, so a key
    /// generated for a write that failed is still searched for.
    private final class AttemptRecordingStore: CredentialStore, @unchecked Sendable {
        private let wrapped: any CredentialStore
        private let lock = NSLock()
        private var attempted: [(key: CredentialKey, value: String)] = []
        var refuseWrites = false

        init(wrapping wrapped: any CredentialStore) {
            self.wrapped = wrapped
        }

        /// attemptedAuthorityKeys is every authority key the module tried to store.
        var attemptedAuthorityKeys: [String] { lock.withLock { attempted.filter { $0.key == .authorityKey }.map(\.value) } }

        func string(for key: CredentialKey) throws -> String? { try wrapped.string(for: key) }
        func setString(_ value: String, for key: CredentialKey) throws { try wrapped.setString(value, for: key) }
        func removeAll(_ keys: [CredentialKey]) throws { try wrapped.removeAll(keys) }

        func setStrings(_ values: [CredentialKey: String]) throws {
            lock.withLock { attempted.append(contentsOf: values.map { (key: $0.key, value: $0.value) }) }
            if refuseWrites { throw FakeCredentialStoreError.simulatedFailure }
            try wrapped.setStrings(values)
        }
    }

    @Test("the authority key is found only in the Keychain across create, renew, rename and a failed write")
    func keyStaysInKeychain() throws {
        let service = "com.yaanfpv.cgmrelay.test.\(UUID().uuidString)"
        defer { Self.deleteKeychainItem(service: service) }
        let keychain = KeychainCredentialStore(service: service)
        let store = AttemptRecordingStore(wrapping: keychain)
        let authority = LocalCertificateAuthority(store: store)

        var handedBack: [LocalCertificateMaterial] = []
        var authorityKeys: [String] = []
        func rememberAuthorityKey() throws {
            authorityKeys.append(try #require(try keychain.string(for: .authorityKey)))
        }

        let started = Date().addingTimeInterval(-2)
        let temporaryDirectory = FileManager.default.temporaryDirectory

        let captured = try Self.captureOutput {
            // Create.
            handedBack.append(try authority.currentMaterial(name: "alpha.local", ipv4s: ["192.168.1.20"]))
            try rememberAuthorityKey()

            // Renew: an expiring server certificate under the same authority.
            let key = try P256.Signing.PrivateKey(pemRepresentation: authorityKeys[0])
            let certificate = try Certificate(pemEncoded: handedBack[0].authorityCertificatePEM)
            let now = Date()
            let expiring = try LocalCertificateAuthority.issueServerCertificate(
                key: P256.Signing.PrivateKey().publicKey, authorityKey: key, authorityCertificate: certificate,
                host: "alpha.local", addresses: ["192.168.1.20"],
                notBefore: LocalCertificateAuthority.whole(now - 3600), notAfter: LocalCertificateAuthority.whole(now + 3600))
            try keychain.setStrings([
                .serverKey: P256.Signing.PrivateKey().pemRepresentation,
                .serverCertificate: try expiring.serializeAsPEM().pemString,
            ])
            handedBack.append(try authority.currentMaterial(name: "alpha.local", ipv4s: ["192.168.1.20"]))
            try rememberAuthorityKey()

            // Rename.
            handedBack.append(try authority.currentMaterial(name: "beta.local", ipv4s: ["192.168.1.20"]))
            try rememberAuthorityKey()

            // A write that fails after the new authority was generated.
            store.refuseWrites = true
            #expect(throws: FakeCredentialStoreError.simulatedFailure) {
                try authority.currentMaterial(name: "gamma.local", ipv4s: [])
            }
            store.refuseWrites = false
        }

        #expect(authorityKeys[0] == authorityKeys[1] && authorityKeys[1] != authorityKeys[2], "renewing keeps the authority key and a rename makes a new one")
        #expect(handedBack.map(\.authorityChange) == [.created, .unchanged, .replaced(.renamed)])

        // Every authority key that was made, including the one whose write failed.
        let attempted = store.attemptedAuthorityKeys
        try #require(attempted.count == 3)
        #expect(attempted[0] == authorityKeys[0] && attempted[1] == authorityKeys[2])
        #expect(!authorityKeys.contains(attempted[2]), "the refused write was for a key of its own")
        let needles = try attempted.map { try P256.Signing.PrivateKey(pemRepresentation: $0) }.flatMap { Self.encodings(of: $0) }

        // The search itself can find a key where one is.
        let planted = temporaryDirectory.appendingPathComponent("planted-\(UUID().uuidString).txt")
        try Data(authorityKeys[0].utf8).write(to: planted)
        defer { try? FileManager.default.removeItem(at: planted) }
        #expect(Self.leaks(needles, inDirectory: temporaryDirectory, since: started) == [planted.lastPathComponent])
        try FileManager.default.removeItem(at: planted)

        #expect(Self.leaks(needles, inDirectory: temporaryDirectory, since: started).isEmpty)
        #expect(Self.contains(needles, in: Data(captured)) == false)
        let defaults = try PropertyListSerialization.data(
            fromPropertyList: UserDefaults.standard.dictionaryRepresentation().mapValues { "\($0)" }, format: .xml, options: 0)
        #expect(Self.contains(needles, in: defaults) == false)
        #expect(Self.contains(needles, in: Data((CommandLine.arguments + ProcessInfo.processInfo.environment.map { "\($0)=\($1)" }).joined(separator: "\n").utf8)) == false)

        // What the module hands back carries the server key, never the authority's.
        for material in handedBack {
            let everything = [material.authorityCertificatePEM, material.serverCertificatePEM, material.serverKeyPEM].joined(separator: "\n")
            #expect(Self.contains(needles, in: Data(everything.utf8) + material.authorityCertificateDER) == false)
        }

        // The Keychain does hold the current authority key.
        #expect(try keychain.string(for: .authorityKey) == authorityKeys[2])
    }

    // MARK: Search

    private static func encodings(of key: P256.Signing.PrivateKey) -> [Data] {
        let pem = key.pemRepresentation
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return [
            key.rawRepresentation,
            key.derRepresentation,
            Data(pem.utf8),
            Data(body.utf8),
            Data(key.rawRepresentation.base64EncodedString().utf8),
            Data(key.derRepresentation.base64EncodedString().utf8),
        ]
    }

    private static func contains(_ needles: [Data], in haystack: Data) -> Bool {
        needles.contains { haystack.range(of: $0) != nil }
    }

    /// leaks returns the names of the files under directory, changed since
    /// the given time, that hold any needle.
    private static func leaks(_ needles: [Data], inDirectory directory: URL, since: Date) -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return []
        }
        var found: [String] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true, (values.fileSize ?? 0) < 20_000_000,
                let modified = values.contentModificationDate, modified >= since,
                let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else { continue }
            if contains(needles, in: data) { found.append(url.lastPathComponent) }
        }
        return found
    }

    /// captureOutput runs body with standard output and standard error
    /// redirected to a file, and returns what was written there.
    private static func captureOutput(_ body: () throws -> Void) throws -> [UInt8] {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("captured-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: path) }
        fflush(stdout)
        fflush(stderr)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        dup2(descriptor, STDOUT_FILENO)
        dup2(descriptor, STDERR_FILENO)
        close(descriptor)
        var failure: (any Error)?
        do { try body() } catch { failure = error }
        fflush(stdout)
        fflush(stderr)
        dup2(savedOut, STDOUT_FILENO)
        dup2(savedErr, STDERR_FILENO)
        close(savedOut)
        close(savedErr)
        if let failure { throw failure }
        return Array((try? Data(contentsOf: path)) ?? Data())
    }

    private static func deleteKeychainItem(service: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}
