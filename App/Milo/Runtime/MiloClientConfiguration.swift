import Foundation

enum PaddleEnvironment: String, Sendable {
    case sandbox
    case production
}

/// Reads client-visible build configuration from the signed application bundle.
enum MiloClientConfiguration {
    static var supabaseAnonKey: String {
        bundleString(for: "MiloSupabaseAnonKey")
    }

    static var paddleClientToken: String {
        bundleString(for: "MiloPaddleClientToken")
    }

    static var paddlePriceID: String {
        bundleString(for: "MiloPaddlePriceID")
    }

    static var paddleEnvironment: PaddleEnvironment? {
        PaddleEnvironment(rawValue: bundleString(for: "MiloPaddleEnvironment").lowercased())
    }

    static var licensePublicKeyBase64: String {
        bundleString(for: "MiloLicensePublicKey")
    }

    static func bundleString(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
