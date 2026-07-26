import Foundation

class SIPChecker {
    static func isSIPEnabled() -> Bool {
        let result = CommandRunner.run("/usr/bin/csrutil", arguments: ["status"])
        guard result.succeeded else {
            MiloLog.error(.sipStatusReadFailed, category: .security, detail: result.stderr)
            return true
        }

        return result.stdout.contains("enabled")
    }
}
