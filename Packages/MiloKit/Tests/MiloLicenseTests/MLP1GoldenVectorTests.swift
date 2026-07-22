import CryptoKit
import Foundation
import MiloLicense
import Testing

@Suite("MLP-v1 golden vector")
struct MLP1GoldenVectorTests {
    @Test("encoded envelope is exactly the canonical JSON bytes")
    func encodedEnvelopeMatchesCanonicalJSON() throws {
        let golden = try Self.loadGoldenVector()
        let decodedEnvelope = try Self.decodeBase64URL(golden.envelopeBase64Url)
        #expect(decodedEnvelope == Data(golden.canonicalJson.utf8))
    }

    @Test("Ed25519 signature verifies and tampered protocol does not")
    func signatureVerifiesAndTamperFails() throws {
        let golden = try Self.loadGoldenVector()
        let publicKeyData = try #require(Data(base64Encoded: golden.publicKeyBase64))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        let signature = try Self.decodeBase64URL(golden.signatureBase64Url)
        let message = Data(golden.canonicalJson.utf8)

        #expect(publicKey.isValidSignature(signature, for: message))

        let tamperedMessage = Data(
            golden.canonicalJson
                .replacingOccurrences(of: #""protocolVersion":1"#, with: #""protocolVersion":2"#)
                .utf8
        )
        #expect(!publicKey.isValidSignature(signature, for: tamperedMessage))
    }

    @Test("protocol version is pinned to MLP-v1")
    func protocolVersionIsPinned() throws {
        let golden = try Self.loadGoldenVector()
        try Self.requireProtocolVersion(golden.canonicalJson)
        #expect(throws: GoldenVectorError.unsupportedProtocolVersion) {
            try Self.requireProtocolVersion(
                golden.canonicalJson.replacingOccurrences(of: #""protocolVersion":1"#, with: #""protocolVersion":2"#)
            )
        }
    }

    @Test("P-256 request fixture freezes exact URL, body, and message bytes")
    func deviceRequestBytesAreFrozen() throws {
        let golden = try Self.loadDeviceRequestVector()
        guard let components = URLComponents(string: golden.url),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased() else {
            throw GoldenVectorError.invalidURL
        }

        var authority = host
        if let port = components.port, port != 443 {
            authority += ":\(port)"
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let requestTarget = path + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        let body = Data(golden.bodyUtf8.utf8)
        let bodyHash = Data(SHA256.hash(data: body))
        let bodyHashBase64URL = Self.encodeBase64URL(bodyHash)
        let frozenBody = try Self.decodeBase64URL(golden.bodyBase64Url)
        let frozenMessage = try Self.decodeBase64URL(golden.messageBase64Url)
        let decodedNonce = try Self.decodeBase64URL(golden.nonce)
        let message = [
            "MLP1",
            golden.method,
            authority,
            requestTarget,
            golden.timestamp,
            golden.nonce,
            bodyHashBase64URL
        ].joined(separator: "\n")

        #expect(authority == golden.authority)
        #expect(requestTarget == golden.requestTarget)
        #expect(body == frozenBody)
        #expect(bodyHashBase64URL == golden.bodySha256Base64Url)
        #expect(message == golden.message)
        #expect(Data(message.utf8) == frozenMessage)
        #expect(decodedNonce.count == 32)
    }

    @Test("P-256 request signature is fixed-width low-s P1363")
    func deviceRequestSignatureIsCanonical() throws {
        let golden = try Self.loadDeviceRequestVector()
        let spki = try Self.decodeBase64URL(golden.publicKeySpkiBase64Url)
        let prefix = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE,
            0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D,
            0x03, 0x01, 0x07, 0x03, 0x42, 0x00
        ])
        guard spki.count == prefix.count + 65, spki.prefix(prefix.count) == prefix else {
            throw GoldenVectorError.invalidSPKI
        }

        let publicKey = try P256.Signing.PublicKey(x963Representation: Data(spki.dropFirst(prefix.count)))
        let signatureData = try Self.decodeBase64URL(golden.signatureP1363Base64Url)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)

        #expect(signatureData.count == 64)
        #expect(Self.isCanonicalP256Signature(signatureData))
        #expect(publicKey.isValidSignature(signature, for: Data(golden.message.utf8)))
        #expect(!publicKey.isValidSignature(signature, for: Data(golden.message.replacingOccurrences(
            of: "\nPOST\n",
            with: "\nGET\n"
        ).utf8)))
    }

    @Test("DER and high-s request signatures remain frozen negative cases")
    func deviceRequestNegativeCasesAreFrozen() throws {
        let golden = try Self.loadDeviceRequestVector()
        let originalDER = try Self.decodeBase64URL(golden.signatureDerBase64Url)
        let highSCase = try #require(golden.negativeCases.first { $0.name == "high-s-p1363" })
        let highS = try Self.decodeBase64URL(highSCase.value)

        #expect(originalDER.count != 64)
        #expect(highS.count == 64)
        #expect(!Self.isCanonicalP256Signature(highS))
        #expect(Set(golden.negativeCases.map(\.expectedError)) == Set([
            "invalid-signature-encoding",
            "non-canonical-signature",
            "invalid-base64url",
            "invalid-nonce",
            "invalid-timestamp",
            "device-signature-invalid"
        ]))
    }

    @Test("MiloLicense module links into the contract test target")
    func miloLicenseModuleLinks() throws {
        let golden = try Self.loadGoldenVector()
        let publicKey = try #require(Data(base64Encoded: golden.publicKeyBase64))
        _ = try MiloLicenseService(licensePublicKey: publicKey)
    }

    private static func loadGoldenVector() throws -> GoldenVector {
        let url = try Self.fixtureURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GoldenVector.self, from: data)
    }

    private static func loadDeviceRequestVector() throws -> DeviceRequestGoldenVector {
        let url = try Self.fixtureURL(named: "mlp-v1-device-request-golden")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DeviceRequestGoldenVector.self, from: data)
    }

    private static func fixtureURL() throws -> URL {
        try fixtureURL(named: "mlp-v1-golden")
    }

    private static func fixtureURL(named name: String) throws -> URL {
        if let nestedURL = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) {
            return nestedURL
        }
        if let rootURL = Bundle.module.url(forResource: name, withExtension: "json") {
            return rootURL
        }
        throw GoldenVectorError.missingFixture
    }

    private static func requireProtocolVersion(_ canonicalJSON: String) throws {
        guard canonicalJSON.contains(#""protocolVersion":1"#) else {
            throw GoldenVectorError.unsupportedProtocolVersion
        }
    }

    private static func decodeBase64URL(_ value: String) throws -> Data {
        guard value.allSatisfy({ character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }) else {
            throw GoldenVectorError.invalidBase64URL
        }

        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch normalized.count % 4 {
        case 0:
            break
        case 2:
            normalized += "=="
        case 3:
            normalized += "="
        default:
            throw GoldenVectorError.invalidBase64URL
        }

        guard let decoded = Data(base64Encoded: normalized) else {
            throw GoldenVectorError.invalidBase64URL
        }
        guard encodeBase64URL(decoded) == value else {
            throw GoldenVectorError.invalidBase64URL
        }
        return decoded
    }

    private static func encodeBase64URL(_ value: Data) -> String {
        value.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isCanonicalP256Signature(_ value: Data) -> Bool {
        guard value.count == 64 else {
            return false
        }
        let r = value.prefix(32)
        let s = value.suffix(32)
        guard r.contains(where: { $0 != 0 }), s.contains(where: { $0 != 0 }) else {
            return false
        }
        let halfOrder = Data([
            0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00,
            0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xDE, 0x73, 0x7D, 0x56, 0xD3, 0x8B, 0xCF, 0x42,
            0x79, 0xDC, 0xE5, 0x61, 0x7E, 0x31, 0x92, 0xA8
        ])
        return s == halfOrder || s.lexicographicallyPrecedes(halfOrder)
    }
}

private enum GoldenVectorError: Error {
    case invalidBase64URL
    case missingFixture
    case invalidSPKI
    case invalidURL
    case unsupportedProtocolVersion
}

private struct GoldenVector: Decodable {
    let publicKeyBase64: String
    let canonicalJson: String
    let envelopeBase64Url: String
    let signatureBase64Url: String
}

private struct DeviceRequestGoldenVector: Decodable {
    let publicKeySpkiBase64Url: String
    let method: String
    let url: String
    let authority: String
    let requestTarget: String
    let timestamp: String
    let nonce: String
    let bodyUtf8: String
    let bodyBase64Url: String
    let bodySha256Base64Url: String
    let message: String
    let messageBase64Url: String
    let signatureDerBase64Url: String
    let signatureP1363Base64Url: String
    let negativeCases: [DeviceRequestNegativeCase]
}

private struct DeviceRequestNegativeCase: Decodable {
    let name: String
    let expectedError: String
    let value: String
}
