import Foundation
import OSLog

enum MiloLog {
    enum Category {
        case general
        case process
        case privileges
        case persistence
        case memory
        case settings
        case selfTest
        case security
    }

    private static let subsystem = "com.monomacaw.milo"

    private static let generalLogger = Logger(subsystem: subsystem, category: "General")
    private static let processLogger = Logger(subsystem: subsystem, category: "Process")
    private static let privilegesLogger = Logger(subsystem: subsystem, category: "Privileges")
    private static let persistenceLogger = Logger(subsystem: subsystem, category: "Persistence")
    private static let memoryLogger = Logger(subsystem: subsystem, category: "Memory")
    private static let settingsLogger = Logger(subsystem: subsystem, category: "Settings")
    private static let selfTestLogger = Logger(subsystem: subsystem, category: "SelfTest")
    private static let securityLogger = Logger(subsystem: subsystem, category: "Security")

    static func error(_ message: String, category: Category = .general) {
        logger(for: category).error("\(message, privacy: .public)")
    }

    static func warning(_ message: String, category: Category = .general) {
        logger(for: category).warning("\(message, privacy: .public)")
    }

    static func info(_ message: String, category: Category = .general) {
        logger(for: category).info("\(message, privacy: .public)")
    }

    private static func logger(for category: Category) -> Logger {
        switch category {
        case .general:
            return generalLogger
        case .process:
            return processLogger
        case .privileges:
            return privilegesLogger
        case .persistence:
            return persistenceLogger
        case .memory:
            return memoryLogger
        case .settings:
            return settingsLogger
        case .selfTest:
            return selfTestLogger
        case .security:
            return securityLogger
        }
    }
}
