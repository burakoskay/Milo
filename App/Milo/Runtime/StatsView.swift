import SwiftUI
import AppKit

struct StatsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            VisualEffectBlur()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                SheetHeader(title: "Statistics & Impact", subtitle: "Your privacy and energy savings", dismiss: dismiss)
                Divider()

                ScrollView {
                    VStack(spacing: 12) {
                        // Summary Cards
                        HStack(spacing: 12) {
                            StatCard(
                                title: "Processes Killed",
                                value: "\(appState.stats.totalProcessesKilled)",
                                icon: "xmark.circle.fill",
                                color: .red
                            )

                            StatCard(
                                title: "RAM Freed",
                                value: String(format: "%.1f GB", appState.stats.totalRAMSavedMB / 1024),
                                icon: "memorychip.fill",
                                color: .blue
                            )
                        }

                        HStack(spacing: 12) {
                            StatCard(
                                title: "Battery Saved",
                                value: String(format: "~%.1f hrs", appState.stats.estimatedBatteryHoursSaved),
                                icon: "battery.100.bolt",
                                color: .green
                            )
                        }

                        // Killed by Vendor
                        if !appState.stats.killedProcessesByVendor.isEmpty {
                            GlassCard {
                                Text("Killed by Vendor")
                                    .font(.headline)
                                Divider().opacity(0.35)
                                VStack(spacing: 6) {
                                    ForEach(appState.stats.killedProcessesByVendor.sorted(by: { $0.value > $1.value }), id: \.key) { vendor, count in
                                        HStack {
                                            Text(vendor)
                                                .font(.subheadline)
                                            Spacer()
                                            Text("\(count)")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        // Top Memory Hogs
                        if !appState.stats.topMemoryHogs.isEmpty {
                            GlassCard {
                                Text("Top Memory Hogs")
                                    .font(.headline)
                                Divider().opacity(0.35)
                                VStack(spacing: 6) {
                                    ForEach(Array(appState.stats.topMemoryHogs.prefix(5)), id: \.processName) { stat in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(stat.processName)
                                                    .font(.subheadline)
                                                Text(stat.vendor)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(String(format: "%.0f MB", stat.memoryMB))
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                        }

                        // Timeline
                        if let first = appState.stats.firstKillDate, let last = appState.stats.lastKillDate {
                            GlassCard {
                                Text("Timeline")
                                    .font(.headline)
                                Divider().opacity(0.35)
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("First kill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(first, style: .date)
                                            .font(.subheadline)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    VStack(alignment: .trailing) {
                                        Text("Latest kill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(last, style: .date)
                                            .font(.subheadline)
                                    }
                                }
                            }
                        }

                        // Action buttons
                        HStack(spacing: 12) {
                            Button {
                                appState.saveStatsReport()
                            } label: {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Export Report")
                                }
                                .font(.subheadline)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                appState.resetStats()
                            } label: {
                                Text("Reset Stats")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 360, height: 520)
    }

    private func formatNumber(_ number: Int) -> String {
        if number >= 1_000_000 {
            return String(format: "%.1fM", Double(number) / 1_000_000)
        } else if number >= 1_000 {
            return String(format: "%.1fK", Double(number) / 1_000)
        } else {
            return "\(number)"
        }
    }
}
