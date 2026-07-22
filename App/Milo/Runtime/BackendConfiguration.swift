import Foundation

enum BackendConfiguration {
    static var supabaseURL: String {
        #if DEBUG
        return Secrets.supabaseURL
        #else
        if let value = Bundle.main.object(forInfoDictionaryKey: "MiloSupabaseURL") as? String,
           Self.isAllowedBackendURL(value) {
            return value
        }
        return "https://monomacaw.com"
        #endif
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
