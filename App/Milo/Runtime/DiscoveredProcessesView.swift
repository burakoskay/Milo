import SwiftUI
import AppKit
import MiloDomain

/// One row of the open-discovery list.
///
/// The row shows *why* a process is or is not actionable rather than silently disabling a
/// checkbox. A control that is off with no stated reason reads as a bug.
struct DiscoveredProcessRow: View {
    let process: DiscoveredProcess
    @Binding var isSelected: Bool
    var onProtect: (() -> Void)?

    private var ownerLabel: String {
        guard let ownerName = process.ownerName else {
            return "uid \(process.effectiveUserID)"
        }
        return ownerName
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(process.name)
                        .font(.system(.body, design: .default))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let reason = process.protectionReason {
                        badge(
                            symbol: "lock.fill",
                            text: reason.summary,
                            tint: .secondary,
                            help: reason.explanation
                        )
                    } else if process.requiresPrivilegedHelper {
                        badge(
                            symbol: "key.fill",
                            text: ownerLabel,
                            tint: .orange,
                            help: "Runs as \(ownerLabel). Milo's approved background helper performs this action."
                        )
                    }

                    if process.isLaunchdManaged {
                        badge(
                            symbol: "arrow.clockwise.circle.fill",
                            text: "Restarts",
                            tint: .blue,
                            help: "launchd manages this process as \(process.launchdLabel ?? "a job") and will start it again."
                        )
                    }
                }

                HStack(spacing: 8) {
                    Text(process.executablePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 4) {
                        ResourceBadge(
                            icon: "cpu",
                            value: String(format: "%.1f%%", process.cpuUsage),
                            isHigh: process.cpuUsage > 10
                        )
                        ResourceBadge(
                            icon: "memorychip",
                            value: String(format: "%.0fMB", process.memoryMB),
                            isHigh: process.memoryMB > 100
                        )
                    }
                }
            }

            Spacer(minLength: 12)

            Text("\(process.pid)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)

            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!process.isActionable)
                .help(process.protectionReason?.explanation ?? "Select \(process.name) for termination")
                .accessibilityLabel(Text("\(process.name), process \(process.pid)"))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .opacity(process.isActionable ? 1 : 0.65)
        .hoverHighlight()
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.executablePath, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            Button {
                NSWorkspace.shared.selectFile(
                    process.executablePath,
                    inFileViewerRootedAtPath: ""
                )
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            if process.isActionable {
                Divider()
                Button {
                    onProtect?()
                } label: {
                    Label("Always Protect This Process", systemImage: "lock")
                }
            }
        }
    }

    private func badge(symbol: String, text: String, tint: Color, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.15)))
        .foregroundStyle(tint)
        .help(help)
    }
}

/// The open-discovery card, shared by the menu bar panel and the dedicated window.
struct DiscoveredProcessesCard: View {
    @ObservedObject var appState: AppState
    /// The panel is short; the window is not.
    let rowLimit: Int

    private var visible: [DiscoveredProcess] {
        appState.visibleDiscovered
    }

    private var shown: [DiscoveredProcess] {
        Array(visible.prefix(rowLimit))
    }

    private var selectedCount: Int {
        appState.selectedDiscovered.count
    }

    var body: some View {
        GlassCard {
            header

            if appState.discoveredProcesses.isEmpty {
                Text("No other background processes were found on this scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                controls
                Divider().opacity(0.35)

                if visible.isEmpty {
                    Text(
                        appState.discoverySearchText.isEmpty
                            ? "Every process found on this scan is one macOS manages. Turn on \"Include protected\" to see them."
                            : "No background process matches “\(appState.discoverySearchText)”."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 4) {
                        ForEach(shown) { process in
                            DiscoveredProcessRow(
                                process: process,
                                isSelected: appState.discoveredSelectionBinding(for: process.pid),
                                onProtect: { appState.protectDiscovered(process) }
                            )
                        }
                    }

                    if visible.count > shown.count {
                        Text("Showing the \(shown.count) largest of \(visible.count). Search to narrow the list.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass.circle.fill")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
            Text("Other Background Processes")
                .font(.headline)
            Spacer()
            Text("\(appState.discoveredActionableCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .help("Background processes Milo can act on")

            if selectedCount > 0 {
                Button {
                    appState.requestKillDiscovered()
                } label: {
                    Text("Terminate \(selectedCount)")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
                .disabled(appState.isKilling)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("Filter by name or path", text: $appState.discoverySearchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            Toggle(isOn: Binding(
                get: { appState.showsProtectedProcesses },
                set: { appState.setShowsProtectedProcesses($0) }
            )) {
                Text("Include protected")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .help("Also list processes Milo will never signal, such as macOS system services.")
        }
    }
}
