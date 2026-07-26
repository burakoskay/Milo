import CryptoKit
import Foundation

enum SparkleSigningError: Error, CustomStringConvertible {
    case usage
    case privateKeyAlreadyExists(String)
    case publicKeyAlreadyExists(String)
    case invalidPrivateKeyLength(Int)
    case writeFailed(String)

    var description: String {
        switch self {
        case .usage:
            return """
            usage:
              swift Tools/sign-appcast.swift generate-key <private-key-out> <public-key-out>
              swift Tools/sign-appcast.swift public-key <private-key> <public-key-out>
              swift Tools/sign-appcast.swift sign-release <archive-path> <private-key> <signature-out>
            """
        case let .privateKeyAlreadyExists(path):
            return "private key already exists: \(path)"
        case let .publicKeyAlreadyExists(path):
            return "public key already exists: \(path)"
        case let .invalidPrivateKeyLength(length):
            return "invalid raw Ed25519 private key length: \(length)"
        case let .writeFailed(path):
            return "failed to write: \(path)"
        }
    }
}

func writeNewFile(_ data: Data, to url: URL, permissions: Int16) throws {
    let path = url.path
    if FileManager.default.fileExists(atPath: path) {
        if permissions == 0o600 {
            throw SparkleSigningError.privateKeyAlreadyExists(path)
        }
        throw SparkleSigningError.publicKeyAlreadyExists(path)
    }
    let attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: permissions)]
    let created = FileManager.default.createFile(atPath: path, contents: data, attributes: attributes)
    if !created {
        throw SparkleSigningError.writeFailed(path)
    }
}

func readPrivateKey(_ url: URL) throws -> Curve25519.Signing.PrivateKey {
    let data = try Data(contentsOf: url)
    guard data.count == 32 else {
        throw SparkleSigningError.invalidPrivateKeyLength(data.count)
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
}

func generateKey(privateKeyURL: URL, publicKeyURL: URL) throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let privateData = privateKey.rawRepresentation
    let publicData = privateKey.publicKey.rawRepresentation.base64EncodedData()
    try writeNewFile(privateData, to: privateKeyURL, permissions: 0o600)
    try writeNewFile(publicData, to: publicKeyURL, permissions: 0o644)
}

func writePublicKey(privateKeyURL: URL, publicKeyURL: URL) throws {
    let privateKey = try readPrivateKey(privateKeyURL)
    let publicData = privateKey.publicKey.rawRepresentation.base64EncodedData()
    try writeNewFile(publicData, to: publicKeyURL, permissions: 0o644)
}

func signRelease(archiveURL: URL, privateKeyURL: URL, signatureURL: URL) throws {
    let privateKey = try readPrivateKey(privateKeyURL)
    let archive = try Data(contentsOf: archiveURL)
    let signature = try privateKey.signature(for: archive)
    try signature.base64EncodedData().write(to: signatureURL, options: [.atomic])
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        throw SparkleSigningError.usage
    }

    switch arguments[1] {
    case "generate-key":
        guard arguments.count == 4 else { throw SparkleSigningError.usage }
        try generateKey(
            privateKeyURL: URL(fileURLWithPath: arguments[2]),
            publicKeyURL: URL(fileURLWithPath: arguments[3])
        )
    case "public-key":
        guard arguments.count == 4 else { throw SparkleSigningError.usage }
        try writePublicKey(
            privateKeyURL: URL(fileURLWithPath: arguments[2]),
            publicKeyURL: URL(fileURLWithPath: arguments[3])
        )
    case "sign-release":
        guard arguments.count == 5 else { throw SparkleSigningError.usage }
        try signRelease(
            archiveURL: URL(fileURLWithPath: arguments[2]),
            privateKeyURL: URL(fileURLWithPath: arguments[3]),
            signatureURL: URL(fileURLWithPath: arguments[4])
        )
    default:
        throw SparkleSigningError.usage
    }
} catch {
    FileHandle.standardError.write(Data("sign-appcast failed: \(error)\n".utf8))
    exit(1)
}
