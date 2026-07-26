import Foundation

enum MiloBuildMode {
    #if MILO_DEVELOPMENT_PREVIEW
    static let isDevelopmentPreview = true
    static let displayName = "Development Preview"
    #else
    static let isDevelopmentPreview = false
    static let displayName = "Production"
    #endif
}
