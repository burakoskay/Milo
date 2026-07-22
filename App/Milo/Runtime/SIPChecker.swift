import Foundation

class SIPChecker {
    static func isSIPEnabled() -> Bool {
        let result = CommandRunner.run("/usr/bin/csrutil", arguments: ["status"])
        guard result.succeeded else {
            MiloLog.error("Failed to check SIP status: \(result.stderr)", category: .security)
            return true
        }

        return result.stdout.contains("enabled")
    }
}
