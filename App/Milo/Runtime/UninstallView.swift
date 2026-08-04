import SwiftUI
import AppKit
import MiloDomain

/// The uninstall sheet.
///
/// The order of operations is stated to the user rather than hidden, because the reason it
/// exists is unintuitive: removing `Milo.app` does not remove Milo. The helper registration
/// lives in macOS's Background Task Management database, so an app dragged to the Trash
/// leaves a root daemon behind.
struct UninstallView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var manager: UninstallManager
    @Environment(\.dismiss) var dismiss

    @State private var removesApplicationBundle: Bool = true
    @State private var hasConfirmed: Bool = false

    var body: some View {
        ZStack {
            VisualEffectBlur()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                SheetHeader(title: "Remove Milo", subtitle: "Uninstall the app and its background helper", dismiss: dismiss)
                Divider()

                ScrollView {
                    VStack(spacing: 16) {
                        if manager.results.isEmpty {
                            explanation
                            planCard
                            optionsCard
                        } else {
                            resultsCard
                        }
                    }
                    .padding(16)
                }

                Divider()
                footer
            }
        }
        .frame(width: MiloPanelMetrics.width, height: MiloPanelMetrics.height)
        .onAppear {
            manager.refreshOrphanedHelpers()
        }
    }

    private var explanation: some View {
        GlassCard {
            Label("Why this exists", systemImage: "info.circle.fill")
                .font(.headline)

            Text("Dragging Milo to the Trash does not fully remove it. Milo's background helper is registered with macOS, not stored inside the app, so deleting the app leaves a helper registered and running with nothing to manage it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("This removes the helper registration first, then Milo's own files, and only then moves the app to the Trash.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var planCard: some View {
        GlassCard {
            Label("What will be removed", systemImage: "trash")
                .font(.headline)

            HStack {
                Text("Background helper")
                Spacer()
                Text(appState.helperStatus.isEnabled ? "Registered" : "Not registered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if manager.plannedItems.isEmpty {
                Text("No Milo data files were found in your Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.plannedItems) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: item.isLegacy ? "clock.arrow.circlepath" : "doc")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.caption)
                            Text(item.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                }
            }

            Text("Nothing outside these paths is touched. Your other applications' data is not affected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var optionsCard: some View {
        GlassCard {
            Label("Options", systemImage: "gearshape")
                .font(.headline)

            Toggle(isOn: $removesApplicationBundle) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move Milo to the Trash and quit")
                    Text("Skipped automatically if the helper cannot be unregistered, so the app is never deleted while its helper is still running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if !manager.orphanedHelpers.isEmpty {
            orphanedHelperCard
        }
    }

    /// A registration from a previous install that Milo cannot remove itself.
    private var orphanedHelperCard: some View {
        GlassCard {
            Label("A helper from an earlier install is still registered", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("macOS only lets an app unregister its own helpers, so Milo cannot remove this one for you. Either turn it off in Login Items & Extensions, or run the command below in Terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(manager.orphanedHelpers) { helper in
                VStack(alignment: .leading, spacing: 4) {
                    Text(helper.serviceIdentifier)
                        .font(.system(size: 11, design: .monospaced))
                    HStack {
                        Text(helper.recoveryCommand)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(helper.recoveryCommand, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            Button("Open Login Items & Extensions") {
                appState.openHelperApprovalSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Never use sfltool resetbtm — it resets background items for every app on this Mac, not just Milo.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resultsCard: some View {
        GlassCard {
            Label("Result", systemImage: allSucceeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(allSucceeded ? .green : .orange)

            ForEach(manager.results) { result in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: symbol(for: result.outcome))
                        .font(.caption)
                        .foregroundStyle(color(for: result.outcome))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.title)
                            .font(.caption)
                        Text(description(for: result))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }

            if !allSucceeded {
                Text("Milo was not fully removed. Resolve the items above before deleting the app, or the background helper will stay registered.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(manager.results.isEmpty ? "Cancel" : "Close") {
                dismiss()
            }
            .buttonStyle(.bordered)

            Spacer()

            if manager.results.isEmpty {
                if hasConfirmed {
                    Button(role: .destructive) {
                        manager.uninstall(removesApplicationBundle: removesApplicationBundle) {}
                    } label: {
                        Text(manager.isRunning ? "Removing…" : "Remove Milo Now")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(manager.isRunning)
                } else {
                    Button(role: .destructive) {
                        hasConfirmed = true
                    } label: {
                        Text("Remove Milo…")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
        .padding(12)
    }

    private var allSucceeded: Bool {
        manager.results.allSatisfy { $0.outcome.succeeded }
    }

    private func symbol(for outcome: UninstallStepResult.Outcome) -> String {
        switch outcome {
        case .removed:
            return "checkmark.circle.fill"
        case .notPresent:
            return "minus.circle"
        case .refused:
            return "hand.raised.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private func color(for outcome: UninstallStepResult.Outcome) -> Color {
        switch outcome {
        case .removed:
            return .green
        case .notPresent:
            return .secondary
        case .refused:
            return .orange
        case .failed:
            return .red
        }
    }

    private func description(for result: UninstallStepResult) -> String {
        switch result.outcome {
        case .removed:
            return "Removed · \(result.detail)"
        case .notPresent:
            return "Nothing to remove · \(result.detail)"
        case .refused(let message):
            return message
        case .failed(let message):
            return message
        }
    }
}
