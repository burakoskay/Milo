import AppKit
import Foundation
import MiloHardening
import MiloLicense
import MiloUpdates
import Security

#if canImport(Sparkle)
import Sparkle
#endif

enum LicenseEnvelopeBootstrapper {
    static func migrateV1FileIfNeeded() {
        return
    }
}

enum KeychainEnvelopeStore {
    private static let service = "com.monomacaw.milo.license"

    static func writeIfAbsent(data: Data, account: String) throws {
        guard !data.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var existing: CFTypeRef?
        let copyStatus = SecItemCopyMatching(query as CFDictionary, &existing)
        if copyStatus == errSecSuccess {
            return
        }
        guard copyStatus == errSecItemNotFound else {
            throw KeychainEnvelopeStoreError.copyFailed(copyStatus)
        }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainEnvelopeStoreError.addFailed(addStatus)
        }
    }

    static func verifiedUpdateFeedState() throws -> AuthenticatedUpdateFeedState {
        let envelopes = try readAllEnvelopeData()
        guard !envelopes.isEmpty else {
            throw KeychainEnvelopeStoreError.itemNotFound
        }

        var lastError: Error?
        for data in envelopes {
            do {
                return try state(from: data)
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw KeychainEnvelopeStoreError.itemNotFound
    }

    private static func readAllEnvelopeData() throws -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainEnvelopeStoreError.copyFailed(status)
        }

        if let data = result as? Data {
            return [data]
        }
        guard let dataList = result as? [Data] else {
            throw KeychainEnvelopeStoreError.invalidEnvelope
        }
        return dataList
    }

    private static func state(from data: Data) throws -> AuthenticatedUpdateFeedState {
        let storedEnvelope = try JSONDecoder().decode(StoredSignedLicenseEnvelope.self, from: data)
        let envelopeData = try decodeEnvelope(storedEnvelope.encodedEnvelope())
        let signatureData = try decodeEnvelope(storedEnvelope.signature)

        _ = try MiloLicenseService().verify(envelope: envelopeData, signature: signatureData)

        let payload = try JSONDecoder().decode(MinimalLicenseEnvelope.self, from: envelopeData)
        guard payload.protocolVersion == 1,
              payload.appId == "milo",
              !payload.licenseId.isEmpty,
              payload.deviceId.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw KeychainEnvelopeStoreError.invalidEnvelope
        }

        return AuthenticatedUpdateFeedState(
            appId: payload.appId,
            licenseId: payload.licenseId,
            deviceHash: payload.deviceId
        )
    }

    private static func decodeEnvelope(_ encoded: String) throws -> Data {
        if let standard = Data(base64Encoded: encoded) {
            return standard
        }

        var normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: normalized) else {
            throw KeychainEnvelopeStoreError.invalidEnvelope
        }
        return data
    }
}

enum KeychainEnvelopeStoreError: Error {
    case itemNotFound
    case copyFailed(OSStatus)
    case addFailed(OSStatus)
    case invalidEnvelope
}

private struct StoredSignedLicenseEnvelope: Decodable {
    let payload: String?
    let envelope: String?
    let signature: String

    func encodedEnvelope() throws -> String {
        if let payload {
            return payload
        }
        if let envelope {
            return envelope
        }
        throw KeychainEnvelopeStoreError.invalidEnvelope
    }
}

private struct MinimalLicenseEnvelope: Decodable {
    let protocolVersion: Int
    let appId: String
    let licenseId: String
    let deviceId: String
}

enum MiloUpdateFeedConfiguration {
    static func baseURL() throws -> URL {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: value),
              url.scheme == "https" else {
            throw MiloUpdateFeedConfigurationError.invalidBaseURL
        }
        return url
    }

}

enum MiloUpdateFeedConfigurationError: Error {
    case invalidBaseURL
}
