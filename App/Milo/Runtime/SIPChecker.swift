import Foundation

class SIPChecker {
    static func isSIPEnabled(
        runner: (String, [String]) -> CommandResult = { cmd, args in CommandRunner.run(cmd, arguments: args) }
    ) -> Bool {
        let result = runner("/usr/bin/csrutil", ["status"])
        guard result.succeeded else {
            MiloLog.error(.sipStatusReadFailed, category: .security, detail: result.stderr)
            return true
        }

        return result.stdout.contains("enabled")
    }
}
