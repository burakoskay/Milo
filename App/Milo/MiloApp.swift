import Darwin
import SwiftUI

@main
struct MiloApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--self-test") {
            let includeDestructive = CommandLine.arguments.contains("--self-test-destructive")
            exit(SelfTestRunner.run(includeDestructive: includeDestructive))
        }

        _ = LicenseManager.shared
        _ = DebloatManager.shared
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
