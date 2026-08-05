import MiloDomain
import SwiftUI

/// The card offering to stop a launchd job that restarted a process the user terminated.
///
/// It exists because Milo already *told* the user what to do — the results toast has long said
/// "launchd restarted one: disable the launch item to stop it" — while giving them no way to do
/// it. Advice with no action is the worst of both: the user learns the termination did not stick
/// and is sent to the command line.
///
/// The card is shared by the menu bar panel and the dedicated window so the two surfaces cannot
/// drift into offering different actions for the same evidence.
struct RespawningJobsCard: View {
    @ObservedObject var appState: AppState

    private var offers: [RespawningLaunchdJob] {
        appState.respawningLaunchdJobs
    }

    private var refusals: [(name: String, refusal: MiloLaunchdDisableRefusal)] {
        appState.refusedLaunchdJobs
    }

    /// The card is absent rather than empty when there is nothing to say. A permanently visible
    /// panel about launchd would be noise on every scan that went fine.
    var isPresented: Bool {
        !offers.isEmpty || !refusals.isEmpty || appState.lastLaunchdDisableOutcome != nil
    }

    var body: some View {
        if isPresented {
            GlassCard {
                header

                if let outcome = appState.lastLaunchdDisableOutcome {
                    outcomeRow(outcome)
                }

                ForEach(offers) { job in
                    offerRow(job)
                }

                ForEach(refusals, id: \.name) { entry in
                    refusalRow(name: entry.name, refusal: entry.refusal)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            Text("Started again by launchd")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
    }

    private func offerRow(_ job: RespawningLaunchdJob) -> some View {
        let isWorking = appState.disablingLaunchdLabels.contains(job.label)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.processName)
                    .font(.system(size: 12, weight: .medium))
                // The label, not a friendly name: it is what will actually be disabled, and
                // what the user needs in order to undo it themselves.
                Text(job.label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if job.requiresPrivilegedHelper {
                    Text("Needs the background helper.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button(isWorking ? "Disabling…" : "Disable Launch Item") {
                appState.requestLaunchdDisable(job)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(isWorking)
            .help("Stops \(job.label) from starting again. This can be undone.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refusalRow(name: String, refusal: MiloLaunchdDisableRefusal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 12, weight: .medium))
            }
            // Why the action is missing. A button that silently is not there reads as a bug.
            Text(refusal.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outcomeRow(_ outcome: LaunchdDisableOutcome) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(outcome.succeeded ? Color.green : Color.orange)
            Text(outcome.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                appState.lastLaunchdDisableOutcome = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Dismiss")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The confirmation for disabling a launchd job.
///
/// Stated as a persistent configuration change rather than as "are you sure", because that is
/// the part the user cannot infer: the job stays disabled across reboots, and the exact command
/// to undo it is shown before they agree to it rather than after.
struct LaunchdDisableConfirmation: ViewModifier {
    @ObservedObject var appState: AppState

    func body(content: Content) -> some View {
        content.confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { appState.pendingLaunchdDisable != nil },
                set: { presented in
                    if !presented {
                        appState.cancelLaunchdDisable()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Disable Launch Item") {
                appState.confirmLaunchdDisable()
            }
            Button("Cancel", role: .cancel) {
                appState.cancelLaunchdDisable()
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationTitle: String {
        guard let job = appState.pendingLaunchdDisable else {
            return "Disable launch item?"
        }
        return "Stop \(job.processName) from starting again?"
    }

    private var confirmationMessage: String {
        guard let job = appState.pendingLaunchdDisable else {
            return ""
        }
        let target = job.requiresPrivilegedHelper
            ? "system/\(job.label)"
            : "gui/\(getuid())/\(job.label)"
        return """
            macOS restarts \(job.processName) because the launch item \(job.label) is enabled. \
            Milo will disable it and stop the copy running now. The change persists across \
            restarts until the item is enabled again.

            This does not delete anything, and it can be undone by running:
            launchctl enable \(target)
            """
    }
}

extension View {
    func launchdDisableConfirmation(appState: AppState) -> some View {
        modifier(LaunchdDisableConfirmation(appState: appState))
    }
}
