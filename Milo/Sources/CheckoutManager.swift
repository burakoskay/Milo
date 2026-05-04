import Foundation
import AuthenticationServices
import AppKit

struct PaddleCheckoutConfiguration: Identifiable {
    let id = UUID()
    let environment: Secrets.PaddleEnvironment
    let clientToken: String
    let priceID: String
    let userID: String
    let customerEmail: String?
}

private struct SupabaseTokenResponse: Decodable {
    let accessToken: String
    let user: SupabaseUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case user
    }
}

private struct SupabaseUser: Decodable {
    let id: String
    let email: String?
}

private struct SupabaseAuthError: Decodable {
    let errorDescription: String?
    let message: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case errorDescription = "error_description"
        case message
        case error
    }
}

private struct SupabaseJWTClaims: Decodable {
    let sub: String
    let email: String?
}

/// Authentication and checkout coordinator for Supabase Auth, SIWA, magic links, and Paddle Checkout.
@MainActor
final class CheckoutManager: NSObject, ObservableObject {
    static let shared = CheckoutManager()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var userEmail: String?
    @Published private(set) var userID: String?
    @Published private(set) var isAuthenticating = false
    @Published private(set) var authError: String?

    private let supabaseURL = Secrets.supabaseURL
    private let supabaseAnonKey = Secrets.supabaseAnonKey
    private let keychainService = "com.monomacaw.milo.auth"
    private let keychainAccount = "supabase_jwt"
    private let magicLinkRedirectURL = "milo://auth-callback"

    override private init() {
        super.init()
        restoreSession()
    }

    // MARK: - Native Sign In With Apple

    func startSignInWithApple() {
        isAuthenticating = true
        authError = nil

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    // MARK: - Email Magic Link

    func sendMagicLink(email: String) async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEmail.contains("@"), normalizedEmail.contains(".") else {
            authError = "Enter a valid email address."
            return
        }

        isAuthenticating = true
        authError = nil

        guard let url = URL(string: "\(supabaseURL)/auth/v1/magiclink") else {
            authError = "Invalid backend URL."
            isAuthenticating = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "email": normalizedEmail,
            "redirect_to": magicLinkRedirectURL
        ]

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                authError = "Invalid response from server."
                isAuthenticating = false
                return
            }

            if httpResponse.statusCode == 200 {
                authError = "Magic link sent. Open it on this Mac to finish sign in."
            } else {
                authError = decodeAuthError(from: data) ?? "Failed to send magic link (HTTP \(httpResponse.statusCode))."
            }
        } catch {
            authError = "Network error: \(error.localizedDescription)"
        }

        isAuthenticating = false
    }

    func handleAuthCallback(url: URL) {
        let parameters = Self.callbackParameters(from: url)

        if let errorDescription = parameters["error_description"] ?? parameters["error"] {
            authError = errorDescription.removingPercentEncoding ?? errorDescription
            isAuthenticating = false
            return
        }

        guard let accessToken = parameters["access_token"], !accessToken.isEmpty else {
            authError = "Magic link callback did not include an access token."
            isAuthenticating = false
            return
        }

        Task {
            await completeAuthentication(accessToken: accessToken, explicitUser: nil)
        }
    }

    // MARK: - Checkout

    func checkoutConfiguration() -> PaddleCheckoutConfiguration? {
        guard isAuthenticated, let userID else {
            authError = "Sign in before starting checkout."
            return nil
        }

        let priceID = Secrets.paddlePriceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard priceID.hasPrefix("pri_"), !priceID.contains("REPLACE") else {
            authError = "Paddle Price ID is not configured."
            return nil
        }

        let clientToken = Secrets.paddleClientToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientToken.isEmpty, !clientToken.contains("REPLACE") else {
            authError = "Paddle client token is not configured."
            return nil
        }

        authError = nil
        return PaddleCheckoutConfiguration(
            environment: Secrets.paddleEnvironment,
            clientToken: clientToken,
            priceID: priceID,
            userID: userID,
            customerEmail: userEmail
        )
    }

    // MARK: - Session Management

    private func restoreSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                authError = "Failed to read session from Keychain (Error: \(status))."
            }
            return
        }

        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            authError = "Stored session is unreadable."
            return
        }

        applySessionMetadata(from: token, explicitUser: nil)
        isAuthenticated = true

        Task {
            await LicenseManager.shared.verifyLicenseAndFetchSignatures(sessionToken: token)
        }
    }

    private func saveSession(token: String) -> Bool {
        guard let data = token.data(using: .utf8) else {
            authError = "Failed to encode session for Keychain."
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            authError = "Failed to replace Keychain session (Error: \(deleteStatus))."
            return false
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            authError = "Failed to save session to Keychain (Error: \(status))."
            return false
        }
        return true
    }

    func logout() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            authError = "Failed to remove session from Keychain (Error: \(status))."
            return
        }

        isAuthenticated = false
        userEmail = nil
        userID = nil
        LicenseManager.shared.clearLocalLicenseState()
    }

    // MARK: - Supabase GoTrue REST Client

    private func exchangeAppleToken(idToken: String) async {
        guard let url = URL(string: "\(supabaseURL)/auth/v1/token?grant_type=id_token") else {
            authError = "Invalid auth endpoint."
            isAuthenticating = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "id_token": idToken,
            "provider": "apple"
        ]

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                authError = "Invalid response from server."
                isAuthenticating = false
                return
            }

            if httpResponse.statusCode == 200 {
                let tokenResponse = try JSONDecoder().decode(SupabaseTokenResponse.self, from: data)
                await completeAuthentication(accessToken: tokenResponse.accessToken, explicitUser: tokenResponse.user)
            } else {
                authError = decodeAuthError(from: data) ?? "Authentication failed (HTTP \(httpResponse.statusCode))."
                isAuthenticating = false
            }
        } catch {
            authError = "Network error: \(error.localizedDescription)"
            isAuthenticating = false
        }
    }

    private func completeAuthentication(accessToken: String, explicitUser: SupabaseUser?) async {
        guard saveSession(token: accessToken) else {
            isAuthenticating = false
            return
        }

        applySessionMetadata(from: accessToken, explicitUser: explicitUser)
        guard userID != nil else {
            authError = "Authenticated session did not include a user ID."
            isAuthenticating = false
            return
        }

        isAuthenticated = true
        isAuthenticating = false
        await LicenseManager.shared.verifyLicenseAndFetchSignatures(sessionToken: accessToken)
    }

    private func applySessionMetadata(from token: String, explicitUser: SupabaseUser?) {
        if let explicitUser {
            userID = explicitUser.id
            userEmail = explicitUser.email
            return
        }

        guard let claims = Self.decodeJWTClaims(token) else {
            return
        }

        userID = claims.sub
        userEmail = claims.email
    }

    private func decodeAuthError(from data: Data) -> String? {
        do {
            let decoded = try JSONDecoder().decode(SupabaseAuthError.self, from: data)
            return decoded.errorDescription ?? decoded.message ?? decoded.error
        } catch {
            return nil
        }
    }

    private static func callbackParameters(from url: URL) -> [String: String] {
        var parameters: [String: String] = [:]

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] {
                if let value = item.value {
                    parameters[item.name] = value
                }
            }
        }

        if let fragment = url.fragment {
            let fragmentComponents = URLComponents(string: "milo://callback?\(fragment)")
            for item in fragmentComponents?.queryItems ?? [] {
                if let value = item.value {
                    parameters[item.name] = value
                }
            }
        }

        return parameters
    }

    private static func decodeJWTClaims(_ token: String) -> SupabaseJWTClaims? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload) else { return nil }

        do {
            return try JSONDecoder().decode(SupabaseJWTClaims.self, from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension CheckoutManager: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            guard let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                Task { @MainActor in
                    self.authError = "Invalid identity token from Apple."
                    self.isAuthenticating = false
                }
                return
            }

            Task { @MainActor in
                await self.exchangeAppleToken(idToken: identityToken)
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            self.authError = "Sign in canceled or failed."
            self.isAuthenticating = false
        }
    }
}

extension CheckoutManager: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let keyWindow = NSApplication.shared.keyWindow {
            return keyWindow
        }
        if let firstWindow = NSApplication.shared.windows.first {
            return firstWindow
        }
        return ASPresentationAnchor()
    }
}
