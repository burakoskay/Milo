import SwiftUI
import AppKit

struct WhitelistView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var whitelistedItems: [String] = []

    var body: some View {
        ZStack {
            VisualEffectBlur()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                SheetHeader(title: "Hidden Processes", subtitle: "Processes you've chosen to ignore", dismiss: dismiss)
                Divider()

                if whitelistedItems.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "eye.slash.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)

                        Text("No Hidden Processes")
                            .font(.headline)

                        Text("Right-click any process and select\n\"Don't Show Again\" to hide it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            GlassCard {
                                HStack {
                                    Text("Hidden Processes")
                                        .font(.headline)
                                    Spacer()
                                    Text("\(whitelistedItems.count)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Divider().opacity(0.35)

                                VStack(spacing: 8) {
                                    ForEach(whitelistedItems, id: \.self) { processName in
                                        HStack {
                                            Image(systemName: "eye.slash.fill")
                                                .foregroundStyle(.secondary)
                                                .font(.caption)

                                            Text(processName)
                                                .font(.subheadline)

                                            Spacer()

                                            Button {
                                                appState.removeFromWhitelist(processName)
                                                refreshList()
                                            } label: {
                                                Text("Unhide")
                                                    .font(.caption.weight(.medium))
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                        .padding(.vertical, 4)
                                        .hoverHighlight()
                                    }
                                }
                            }

                            if !whitelistedItems.isEmpty {
                                Button {
                                    WhitelistManager.shared.clearWhitelist()
                                    refreshList()
                                    appState.scanProcesses()
                                } label: {
                                    HStack {
                                        Image(systemName: "trash")
                                        Text("Clear All Hidden")
                                    }
                                    .font(.subheadline)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .frame(width: 360, height: 480)
        .onAppear {
            refreshList()
        }
    }

    private func refreshList() {
        whitelistedItems = WhitelistManager.shared.getWhitelistedProcesses()
    }
}
