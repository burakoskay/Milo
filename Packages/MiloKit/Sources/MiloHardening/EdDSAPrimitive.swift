import CryptoKit
import Foundation

/// Retains Swift cryptographic trampoline symbols that are invoked by C hardening code.
public enum MiloHardeningPrimitives {
    /// Forces the Swift linker to keep the C-callable primitive entry points in final products.
    public static func retain() {
        _ = mhEd25519VerifyPrimitive(nil, 0, nil, 0, nil, 0)
        _ = mhChaChaPolyOpenPrimitive(nil, 0, nil, 0, nil, 0)
    }
}

/// Verifies an Ed25519 signature for the C license verifier.
#if compiler(>=6.3)
@used
#endif
@_cdecl("mh_ed25519_verify_primitive")
// swiftlint:disable:next function_parameter_count
public func mhEd25519VerifyPrimitive(
    _ messagePointer: UnsafePointer<UInt8>?,
    _ messageLength: Int,
    _ signaturePointer: UnsafePointer<UInt8>?,
    _ signatureLength: Int,
    _ publicKeyPointer: UnsafePointer<UInt8>?,
    _ publicKeyLength: Int
) -> Int32 {
    guard let messagePointer, let signaturePointer, let publicKeyPointer else { return 0 }
    guard messageLength > 0, signatureLength == 64, publicKeyLength == 32 else { return 0 }
    let message = Data(bytes: messagePointer, count: messageLength)
    let signature = Data(bytes: signaturePointer, count: signatureLength)
    let publicKeyData = Data(bytes: publicKeyPointer, count: publicKeyLength)
    do {
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        return publicKey.isValidSignature(signature, for: message) ? 1 : 0
    } catch {
        return 0
    }
}

/// Opens a ChaCha20-Poly1305 sealed box for the C honeypot verifier.
#if compiler(>=6.3)
@used
#endif
@_cdecl("mh_chachapoly_open_primitive")
// swiftlint:disable:next function_parameter_count
public func mhChaChaPolyOpenPrimitive(
    _ combinedPointer: UnsafePointer<UInt8>?,
    _ combinedLength: Int,
    _ keyPointer: UnsafePointer<UInt8>?,
    _ keyLength: Int,
    _ outputPointer: UnsafeMutablePointer<UInt8>?,
    _ outputCapacity: Int
) -> Int32 {
    guard let combinedPointer, let keyPointer, let outputPointer else { return 0 }
    guard combinedLength > 0, keyLength == 32, outputCapacity > 0 else { return 0 }
    let combined = Data(bytes: combinedPointer, count: combinedLength)
    let keyData = Data(bytes: keyPointer, count: keyLength)
    do {
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: keyData))
        guard plaintext.count <= outputCapacity else { return 0 }
        plaintext.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            outputPointer.update(from: baseAddress, count: plaintext.count)
        }
        return Int32(plaintext.count)
    } catch {
        return 0
    }
}
