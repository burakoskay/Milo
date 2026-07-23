import SwiftUI
import AuthenticationServices
import WebKit

struct PaywallView: View {
    @StateObject private var checkoutManager = CheckoutManager.shared
    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var emailInput = ""
    @State private var checkoutConfiguration: PaddleCheckoutConfiguration?
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @AppStorage("Milo.appThemeColor") var appThemeColor: String = "System"

    var body: some View {
        VStack(spacing: 0) {
            if licenseManager.isVerifying {
                Text("Verifying license status...")
                    .font(.caption)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundStyle(Color.accentColor)
            }

            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .edgesIgnoringSafeArea(.top)

                VStack(spacing: 12) {
                    let imageName = colorScheme == .dark ? "milo_white" : "milo_black"
                    if let imagePath = Bundle.main.path(forResource: imageName, ofType: "png"),
                       let nsImage = NSImage(contentsOfFile: imagePath) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                    } else {
                        // Fallback
                        Image(systemName: "shield.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                            .foregroundStyle(.blue)
                    }

                    Text("Milo Pro")
                        .font(.system(size: 24, weight: .bold, design: .default))

                    Text("Take absolute control of your Mac.")
                        .font(.system(size: 14, weight: .medium, design: .default))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(16)
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "waveform.circle.fill",
                    color: .purple,
                    title: "Terminate Apple Intelligence",
                    description: "Instantly halt background AI daemons."
                )
                FeatureRow(
                    icon: "network.badge.shield.half.filled",
                    color: .blue,
                    title: "Block Cloud Telemetry",
                    description: "Dynamically block tracking from Adobe, Microsoft, & Google."
                )
                FeatureRow(
                    icon: "cpu.fill",
                    color: .orange,
                    title: "Reclaim Resources",
                    description: "Free up RAM and CPU cycles for your professional work."
                )
            }
            .padding(24)

            Spacer()

            VStack(spacing: 16) {
                if checkoutManager.isAuthenticated {
                    authenticatedSection
                } else {
                    unauthenticatedSection
                }

                if let error = checkoutManager.authError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(error.localizedCaseInsensitiveContains("sent") ? .green : .red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Not Now") {
                    dismiss()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .padding(24)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 420, height: 640)
        .background(VisualEffectBlur())
        .tint(tintColorOverride)
        .sheet(item: $checkoutConfiguration) { configuration in
            PaddleCheckoutView(configuration: configuration) {
                checkoutConfiguration = nil
            }
            .frame(width: 520, height: 680)
        }
    }

    private var authenticatedSection: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)

                Text("Authenticated")
                    .font(.headline)

                if let email = checkoutManager.userEmail {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                checkoutConfiguration = checkoutManager.checkoutConfiguration()
            } label: {
                Text("Start Free Trial / Upgrade to Pro")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.accentColor)
        }
    }

    private var unauthenticatedSection: some View {
        Group {
            if checkoutManager.isAuthenticating {
                ProgressView("Authenticating...")
                    .progressViewStyle(.circular)
                    .padding()
            } else {
                VStack(spacing: 14) {
                    SignInWithAppleButton(
                        .signIn,
                        onRequest: { request in
                            _ = checkoutManager.configureSignInWithAppleRequest(request)
                        },
                        onCompletion: { result in
                            switch result {
                            case .success(let authorization):
                                checkoutManager.handleSignInWithAppleAuthorization(authorization)
                            case .failure:
                                checkoutManager.handleSignInWithAppleFailure()
                            }
                        }
                    )
                    .signInWithAppleButtonStyle(NSApp.effectiveAppearance.name == .darkAqua ? .white : .black)
                    .frame(height: 40)
                    .frame(maxWidth: .infinity)

                    HStack {
                        VStack { Divider() }
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack { Divider() }
                    }
                    .padding(.horizontal, 8)

                    HStack {
                        TextField("Email address", text: $emailInput)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)

                        Button("Magic Link") {
                            Task {
                                await checkoutManager.sendMagicLink(email: emailInput)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(emailInput.isEmpty || !emailInput.contains("@"))
                    }
                }
            }
        }
    }

    private var tintColorOverride: Color? {
        switch appThemeColor {
        case "Blue": return .blue
        case "Purple": return .purple
        case "Pink": return .pink
        case "Red": return .red
        case "Orange": return .orange
        case "Yellow": return .yellow
        case "Green": return .green
        case "Gray": return .gray
        default: return nil
        }
    }
}

private struct PaddleCheckoutView: NSViewRepresentable {
    let configuration: PaddleCheckoutConfiguration
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.userContentController.add(context.coordinator, name: "miloCheckout")

        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.loadHTMLString(Self.html(for: configuration), baseURL: URL(string: "https://checkout.monomacaw.com"))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    private static func html(for configuration: PaddleCheckoutConfiguration) -> String {
        let payload = PaddleHTMLPayload(
            environment: configuration.environment.javascriptName,
            clientToken: configuration.clientToken,
            priceID: configuration.priceID,
            userID: configuration.userID,
            customerEmail: configuration.customerEmail
        )

        let json: String
        do {
            let data = try JSONEncoder().encode(payload)
            json = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "</", with: "<\\/") ?? "{}"
        } catch {
            MiloLog.error("Failed to encode Paddle checkout payload: \(error.localizedDescription)", category: .security)
            json = "{}"
        }

        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              color: #f5f5f7;
            }
            #checkout-container {
              width: 100%;
              min-height: 620px;
            }
            #status {
              padding: 16px;
              color: #6e6e73;
              font-size: 13px;
              text-align: center;
            }
          </style>
        </head>
        <body>
          <div id="status">Loading secure checkout...</div>
          <div id="checkout-container"></div>
          <script src="https://cdn.paddle.com/paddle/v2/paddle.js"></script>
          <script>
            const config = \(json);
            const post = (message) => window.webkit.messageHandlers.miloCheckout.postMessage(message);
            const status = document.getElementById("status");
            const customer = config.customerEmail ? { email: config.customerEmail } : undefined;

            try {
              if (config.environment === "sandbox") {
                Paddle.Environment.set("sandbox");
              }
              Paddle.Initialize({
                token: config.clientToken,
                eventCallback: function(event) {
                  if (event && event.name === "checkout.completed") {
                    post({ type: "completed" });
                  }
                  if (event && event.name === "checkout.error") {
                    post({ type: "error", message: "Paddle checkout failed." });
                  }
                }
              });
              status.remove();
              Paddle.Checkout.open({
                items: [{ priceId: config.priceID, quantity: 1 }],
                customer: customer,
                customData: { user_id: config.userID },
                settings: {
                  displayMode: "inline",
                  frameTarget: "checkout-container",
                  frameInitialHeight: 620,
                  frameStyle: "width: 100%; min-width: 312px; background-color: transparent; border: none;"
                }
              });
            } catch (error) {
              status.textContent = "Checkout could not be loaded.";
              post({ type: "error", message: String(error && error.message ? error.message : error) });
            }
          </script>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            if type == "completed" {
                onClose()
            }
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let host = navigationAction.request.url?.host {
                let allowedHosts = ["paddle.com", "paddlejs-checkout.paddle.com", "monomacaw.com"]
                if allowedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                    decisionHandler(.allow)
                    return
                }
            } else if navigationAction.request.url?.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }
    }
}

private struct PaddleHTMLPayload: Encodable {
    let environment: String
    let clientToken: String
    let priceID: String
    let userID: String
    let customerEmail: String?
}

private extension PaddleEnvironment {
    var javascriptName: String {
        switch self {
        case .sandbox:
            return "sandbox"
        case .production:
            return "production"
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(color)
                .frame(width: 32, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .default))
                Text(description)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
