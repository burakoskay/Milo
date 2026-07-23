import Foundation

enum BackendConfigurationError: LocalizedError {
    case invalidServiceURL
    case invalidWebsitePath

    var errorDescription: String? {
        switch self {
        case .invalidServiceURL:
            return "Milo's service URL is invalid. Reinstall Milo from monomacaw.com."
        case .invalidWebsitePath:
            return "Milo could not construct the requested Monomacaw page."
        }
    }
}

enum BackendConfiguration {
    private static let productionServiceURL = "https://monomacaw.com"

    static func serviceBaseURL() throws -> URL {
        let configured = MiloClientConfiguration.serviceBaseURLString
        let value = configured.isEmpty ? productionServiceURL : configured
        guard let url = validatedServiceBaseURL(value) else {
            throw BackendConfigurationError.invalidServiceURL
        }
        return url
    }

    static func websiteURL(path: String) throws -> URL {
        guard path.hasPrefix("/"),
              !path.hasPrefix("//"),
              !path.contains("?"),
              !path.contains("#"),
              let url = URL(string: path, relativeTo: try serviceBaseURL())?.absoluteURL,
              url.host(percentEncoded: false) == "monomacaw.com" else {
            throw BackendConfigurationError.invalidWebsitePath
        }
        return url
    }

    static func validatedServiceBaseURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "monomacaw.com",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        components.scheme = "https"
        components.host = "monomacaw.com"
        components.path = ""
        return components.url
    }
}
