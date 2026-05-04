import Foundation
import os

class SIPChecker {
    static func isSIPEnabled() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/csrutil"
        task.arguments = ["status"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains("enabled")
            }
        } catch {
            Logger.sip.error("Failed to check SIP status: \(error, privacy: .public)")
        }

        return true // Assume enabled if check fails for safety
    }
}
