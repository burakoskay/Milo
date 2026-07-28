import Foundation

// Simulate the logic in validatePlistPath
func bench() {
    let path = "~/Library/LaunchAgents/com.apple.example.plist"

    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<10000 {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let _ = standardized
    }
    print("Time: \(CFAbsoluteTimeGetCurrent() - start)")
}
// bench()
