import Foundation

enum BackendConfiguration {
    static var supabaseURL: String {
        let value = MiloClientConfiguration.bundleString(for: "MiloSupabaseURL")
        if Self.isAllowedBackendURL(value) {
            return value
        }
        return "https://monomacaw.com"
    }

    private static func isAllowedBackendURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme == "https",
              let host = url.host(percentEncoded: false) else {
            return false
        }
        return host == "monomacaw.com" || host.hasSuffix(".supabase.co")
    }
}
