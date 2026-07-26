import Foundation

enum MiloConfigurationEnvironment: String, Sendable {
    case development
    case production
}

/// Reads public, target-specific MLP-v1 values from the signed application bundle.
enum MiloClientConfiguration {
    static var environmentString: String {
        bundleString(for: "MiloConfigurationEnvironment")
    }

    static var serviceBaseURLString: String {
        bundleString(for: "MiloServiceBaseURL")
    }

    static var licensePublicKeyBase64URL: String {
        bundleString(for: "MiloLicensePublicKey")
    }

    static func bundleString(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
