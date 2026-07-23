import Foundation

/// Reads the two public MLP-v1 client values from the signed application bundle.
enum MiloClientConfiguration {
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
