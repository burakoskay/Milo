import CryptoKit
import Foundation

enum ObfuscateStringsError: Error {
    case usage
    case invalidInput
}

func encrypt(_ plaintext: Data) throws -> String {
    let key = SymmetricKey(size: .bits128)
    let box = try AES.GCM.seal(plaintext, using: key)
    guard let combined = box.combined else {
        throw ObfuscateStringsError.invalidInput
    }
    let keyBytes = key.withUnsafeBytes { Data($0) }
    return """
    {
      "key": "\(keyBytes.base64EncodedString())",
      "ciphertext": "\(combined.base64EncodedString())"
    }
    """
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw ObfuscateStringsError.usage
    }
    let plaintext = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let output = try encrypt(plaintext).data(using: .utf8)
    guard let output else {
        throw ObfuscateStringsError.invalidInput
    }
    try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: [.atomic])
} catch {
    FileHandle.standardError.write(Data("obfuscate-strings failed: \(error)\n".utf8))
    exit(1)
}
