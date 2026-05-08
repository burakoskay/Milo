import Foundation
import AuthenticationServices
import AppKit
import CryptoKit

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
    private let magicLinkStateAccount = "magic_link_state"
    private let magicLinkRedirectURL = "milo://auth-callback"
    private var currentAppleNonce: String?

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
        guard configureSignInWithAppleRequest(request) else {
            isAuthenticating = false
            return
        }

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    @discardableResult
    func configureSignInWithAppleRequest(_ request: ASAuthorizationAppleIDRequest) -> Bool {
        isAuthenticating = true
        authError = nil
        request.requestedScopes = [.email]

        do {
            let nonce = try Self.randomNonceString()
            currentAppleNonce = nonce
            request.nonce = Self.sha256(nonce)
            return true
        } catch {
            authError = "Unable to start Sign in with Apple securely: \(error.localizedDescription)"
            currentAppleNonce = nil
            return false
        }
    }

    func handleSignInWithAppleAuthorization(_ authorization: ASAuthorization) {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityTokenData = appleIDCredential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8) else {
            currentAppleNonce = nil
            authError = "Invalid identity token from Apple."
            isAuthenticating = false
            return
        }

        Task { @MainActor in
            await self.exchangeAppleToken(idToken: identityToken)
        }
    }

    func handleSignInWithAppleFailure() {
        currentAppleNonce = nil
        authError = "Sign in canceled or failed."
        isAuthenticating = false
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

        let redirectURL: String
        do {
            let state = try Self.randomNonceString()
            guard saveMagicLinkState(state) else {
                isAuthenticating = false
                return
            }
            guard let statefulRedirectURL = Self.redirectURLWithState(baseURL: magicLinkRedirectURL, state: state) else {
                authError = "Invalid magic link redirect URL."
                deleteMagicLinkState()
                isAuthenticating = false
                return
            }
            redirectURL = statefulRedirectURL
        } catch {
            authError = "Unable to create a secure magic link state token: \(error.localizedDescription)"
            isAuthenticating = false
            return
        }

        let body: [String: String] = [
            "email": normalizedEmail,
            "redirect_to": redirectURL
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
                deleteMagicLinkState()
                authError = decodeAuthError(from: data) ?? "Failed to send magic link (HTTP \(httpResponse.statusCode))."
            }
        } catch {
            deleteMagicLinkState()
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

        guard let savedState = readMagicLinkState() else {
            authError = "No pending magic link sign-in was started on this Mac."
            isAuthenticating = false
            return
        }

        guard let state = parameters["state"], state == savedState else {
            authError = "Invalid or missing state token. Link may have expired or been intercepted."
            isAuthenticating = false
            return
        }
        deleteMagicLinkState()

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
        guard Self.isValidPaddlePriceID(priceID) else {
            authError = "Paddle Price ID is not configured."
            return nil
        }

        let clientToken = Secrets.paddleClientToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidPaddleClientToken(clientToken, environment: Secrets.paddleEnvironment) else {
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
            if let userID = self.userID {
                await LicenseManager.shared.verifyLicenseAndFetchSignatures(sessionToken: token, userID: userID)
            }
        }
    }

    private func saveSession(token: String) -> Bool {
        saveKeychainString(token, account: keychainAccount, failurePrefix: "session")
    }

    private func saveMagicLinkState(_ state: String) -> Bool {
        saveKeychainString(state, account: magicLinkStateAccount, failurePrefix: "magic link state")
    }

    private func saveKeychainString(_ value: String, account: String, failurePrefix: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            authError = "Failed to encode \(failurePrefix) for Keychain."
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            authError = "Failed to replace Keychain \(failurePrefix) (Error: \(deleteStatus))."
            return false
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            authError = "Failed to save \(failurePrefix) to Keychain (Error: \(status))."
            return false
        }
        return true
    }

    private func readMagicLinkState() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: magicLinkStateAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                authError = "Failed to read magic link state from Keychain (Error: \(status))."
            }
            return nil
        }
        guard let data = item as? Data,
              let state = String(data: data, encoding: .utf8),
              !state.isEmpty else {
            authError = "Stored magic link state is unreadable."
            return nil
        }
        return state
    }

    private func deleteMagicLinkState() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: magicLinkStateAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            MiloLog.warning("Failed to delete magic link state from Keychain (Error: \(status))", category: .security)
        }
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
        guard let nonce = currentAppleNonce else {
            authError = "Missing Sign in with Apple nonce."
            isAuthenticating = false
            return
        }
        currentAppleNonce = nil

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
            "provider": "apple",
            "nonce": nonce
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
        if let userID = self.userID {
            await LicenseManager.shared.verifyLicenseAndFetchSignatures(sessionToken: accessToken, userID: userID)
        }
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

    private static func redirectURLWithState(baseURL: String, state: String) -> String? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "state" }
        queryItems.append(URLQueryItem(name: "state", value: state))
        components.queryItems = queryItems
        return components.url?.absoluteString
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
    // MARK: - Security Helpers

    private static func randomNonceString(length: Int = 32) throws -> String {
        guard length > 0 else {
            throw NSError(domain: "Milo.CheckoutManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nonce length must be positive"])
        }
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)
        guard errorCode == errSecSuccess else {
            throw NSError(domain: "Milo.CheckoutManager", code: Int(errorCode), userInfo: [NSLocalizedDescriptionKey: "Secure random generation failed"])
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = randomBytes.map { charset[Int($0) % charset.count] }
        return String(nonce)
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func isValidPaddleClientToken(_ token: String, environment: Secrets.PaddleEnvironment) -> Bool {
        let expectedPrefix: String
        switch environment {
        case .sandbox:
            expectedPrefix = "test_"
        case .production:
            expectedPrefix = "live_"
        }
        guard token.hasPrefix(expectedPrefix) else { return false }

        let suffix = token.dropFirst(expectedPrefix.count)
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return suffix.count >= 16
            && suffix.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private static func isValidPaddlePriceID(_ priceID: String) -> Bool {
        priceID.range(of: #"^pri_[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension CheckoutManager: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            self.handleSignInWithAppleAuthorization(authorization)
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            self.handleSignInWithAppleFailure()
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
