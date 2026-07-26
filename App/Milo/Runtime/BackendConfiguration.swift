import Foundation

enum BackendConfigurationError: LocalizedError {
    case invalidEnvironment
    case invalidServiceURL
    case invalidWebsitePath

    var errorDescription: String? {
        switch self {
        case .invalidEnvironment:
            return "Milo's build environment is invalid. Reinstall Milo from monomacaw.com."
        case .invalidServiceURL:
            return "Milo's service URL is invalid. Reinstall Milo from monomacaw.com."
        case .invalidWebsitePath:
            return "Milo could not construct the requested Monomacaw page."
        }
    }
}

enum BackendConfiguration {
    private static let productionOrigin = "https://monomacaw.com"

    static func serviceBaseURL() throws -> URL {
        guard let environment = MiloConfigurationEnvironment(
            rawValue: MiloClientConfiguration.environmentString
        ) else {
            throw BackendConfigurationError.invalidEnvironment
        }
        guard let url = validatedHTTPSOrigin(MiloClientConfiguration.serviceBaseURLString) else {
            throw BackendConfigurationError.invalidServiceURL
        }

        switch environment {
        case .production:
            guard url.absoluteString == productionOrigin else {
                throw BackendConfigurationError.invalidServiceURL
            }
        case .development:
            #if DEBUG
            guard url.absoluteString != productionOrigin else {
                throw BackendConfigurationError.invalidServiceURL
            }
            #else
            throw BackendConfigurationError.invalidEnvironment
            #endif
        }
        return url
    }

    static func websiteURL(path: String) throws -> URL {
        guard let websiteOrigin = validatedHTTPSOrigin(productionOrigin) else {
            throw BackendConfigurationError.invalidWebsitePath
        }
        guard path.hasPrefix("/"),
              !path.hasPrefix("//"),
              !path.contains("?"),
              !path.contains("#"),
              let url = URL(string: path, relativeTo: websiteOrigin)?.absoluteURL,
              url.host(percentEncoded: false) == "monomacaw.com" else {
            throw BackendConfigurationError.invalidWebsitePath
        }
        return url
    }

    static func validatedHTTPSOrigin(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              isValidASCIIDNSHost(host),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        components.scheme = "https"
        components.host = host
        components.path = ""
        return components.url
    }

    private static func isValidASCIIDNSHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else {
            return false
        }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-" else {
                return false
            }
            return label.utf8.allSatisfy { byte in
                (byte >= 0x61 && byte <= 0x7A)
                    || (byte >= 0x30 && byte <= 0x39)
                    || byte == 0x2D
            }
        }
    }
}
