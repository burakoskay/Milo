import SwiftUI
import MiloLicense

struct PaywallView: View {
    @ObservedObject private var licenseManager = LicenseManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("Milo.appThemeColor") private var appThemeColor = "System"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    features
                    Divider()
                    licenseSection

                    if let error = licenseManager.licenseError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("license-error")
                    }
                }
                .padding(24)
            }

            Divider()
            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(16)
        }
        .frame(width: 440, height: 660)
        .background(VisualEffectBlur())
        .tint(tintColorOverride)
    }

    private var header: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            VStack(spacing: 10) {
                let imageName = colorScheme == .dark ? "milo_white" : "milo_black"
                if let imagePath = Bundle.main.path(forResource: imageName, ofType: "png"),
                   let nsImage = NSImage(contentsOfFile: imagePath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "shield.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.blue)
                }

                Text("Milo Pro")
                    .font(.system(size: 24, weight: .bold))

                Text("Explicit, local-first control over background processes.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 26)
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
            .accessibilityLabel("Close")
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            FeatureRow(
                icon: "eye.fill",
                color: .purple,
                title: "Truthful process visibility",
                description: "See the processes Milo can identify before deciding whether to act."
            )
            FeatureRow(
                icon: "hand.raised.fill",
                color: .blue,
                title: "Explicit local actions",
                description: "Milo performs process-control actions only after you request them."
            )
            FeatureRow(
                icon: "checkmark.seal.fill",
                color: .orange,
                title: "Signed Pro capability",
                description: "Pro access is granted only by a device-bound, cryptographically verified license."
            )
        }
    }

    @ViewBuilder
    private var licenseSection: some View {
        if licenseManager.isSubscribed {
            activeLicenseSection
        } else if let challenge = licenseManager.pairingChallenge {
            pairingSection(challenge)
        } else {
            lockedLicenseSection
        }
    }

    private var activeLicenseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Milo Pro is active", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .accessibilityIdentifier("license-active")

            if let expiration = licenseManager.licenseExpiresAt {
                Text("Offline access is valid until \(expiration.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh License") {
                    Task {
                        await licenseManager.refreshLicense()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Manage Account") {
                    licenseManager.openAccount()
                }
                .buttonStyle(.bordered)
            }

            Button("Disconnect This Mac", role: .destructive) {
                licenseManager.clearLocalLicenseState()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .disabled(licenseManager.isVerifying)
        .overlay(alignment: .trailing) {
            if licenseManager.isVerifying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing license")
            }
        }
    }

    private var lockedLicenseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair this Mac")
                .font(.headline)

            Text("Purchase or manage Milo Pro in your browser, then approve a short-lived pairing code. Browser cookies, account tokens, and payment credentials never enter the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task {
                    await licenseManager.startEnrollment()
                }
            } label: {
                HStack {
                    if licenseManager.isVerifying {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(licenseManager.isVerifying ? "Starting Pairing…" : "Start Secure Pairing")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(licenseManager.isVerifying)
            .accessibilityIdentifier("start-secure-pairing")

            Button("Open Monomacaw Account") {
                licenseManager.openAccount()
            }
            .buttonStyle(.bordered)
            .disabled(licenseManager.isVerifying)
        }
    }

    private func pairingSection(_ challenge: MLPEnrollmentChallenge) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Approve this pairing code")
                .font(.headline)

            Text(challenge.pairingCode)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel("Pairing code \(challenge.pairingCode)")
                .accessibilityIdentifier("pairing-code")

            Text("Expires \(challenge.expiresAt.formatted(date: .omitted, time: .standard)).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Open Account & Devices in your browser, sign in, enter the code, and approve this Mac. Then return here to complete pairing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open Account & Devices") {
                    licenseManager.openAccountDevices()
                }
                .buttonStyle(.bordered)

                Button("Complete Pairing") {
                    Task {
                        await licenseManager.completeEnrollment()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(licenseManager.isVerifying)

            Button("Generate a New Code") {
                Task {
                    await licenseManager.startEnrollment()
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(licenseManager.isVerifying)

            if licenseManager.isVerifying {
                ProgressView("Checking pairing approval…")
                    .controlSize(.small)
                    .accessibilityIdentifier("pairing-progress")
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
                    .font(.system(size: 14, weight: .semibold))
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
