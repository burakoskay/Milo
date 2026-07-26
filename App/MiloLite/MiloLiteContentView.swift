import AppKit
import SwiftUI

struct MiloLiteRunningApplication: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let processIdentifier: Int32
}

@MainActor
final class MiloLiteScannerModel: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case loaded(applications: [MiloLiteRunningApplication], omittedCount: Int)
    }

    @Published private(set) var state: State = .idle

    func scan() {
        state = .scanning

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        var omittedCount = 0
        let applications: [MiloLiteRunningApplication] = NSWorkspace.shared.runningApplications.compactMap { application -> MiloLiteRunningApplication? in
            let processIdentifier = application.processIdentifier
            guard processIdentifier > 0,
                  processIdentifier != currentProcessIdentifier,
                  let name = application.localizedName,
                  !name.isEmpty else {
                omittedCount += 1
                return nil
            }

            let bundleIdentifier = application.bundleIdentifier
            return MiloLiteRunningApplication(
                id: "\(processIdentifier):\(bundleIdentifier ?? "no-bundle-id")",
                name: name,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier
            )
        }
        .sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.processIdentifier < rhs.processIdentifier
        }

        state = .loaded(applications: applications, omittedCount: omittedCount)
    }
}

struct MiloLiteContentView: View {
    @StateObject private var scanner = MiloLiteScannerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            limitationNotice
            content
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            if scanner.state == .idle {
                scanner.scan()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Milo Lite")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("miloLite.title")
                Text("Read-only running application report")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Scan Again") {
                scanner.scan()
            }
            .accessibilityIdentifier("miloLite.scan")
        }
    }

    private var limitationNotice: some View {
        Label {
            Text("Milo Lite reports application processes exposed by AppKit. It does not inspect background daemons and cannot stop, disable, or modify anything.")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("miloLite.limitations")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch scanner.state {
        case .idle, .scanning:
            HStack {
                Spacer()
                ProgressView("Scanning visible applications…")
                Spacer()
            }
            .frame(maxHeight: .infinity)
        case .loaded(let applications, let omittedCount):
            if applications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.questionmark")
                        .font(.largeTitle)
                    Text("No visible running applications were reported.")
                        .font(.headline)
                    Text("This can reflect current sandbox or system visibility and is not proof that no background software is running.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(applications) { application in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(application.name)
                            .font(.headline)
                        HStack(spacing: 8) {
                            Text("PID \(application.processIdentifier)")
                            if let bundleIdentifier = application.bundleIdentifier {
                                Text(bundleIdentifier)
                            } else {
                                Text("No bundle identifier reported")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                .overlay(alignment: .bottomTrailing) {
                    if omittedCount > 0 {
                        Text("\(omittedCount) incomplete record\(omittedCount == 1 ? "" : "s") omitted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
        }
    }
}
