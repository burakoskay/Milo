import Foundation
import OSLog

enum MiloLog {
    enum Category: Sendable {
        case general
        case process
        case privileges
        case persistence
        case memory
        case settings
        case selfTest
        case security
    }

    enum Code: String, Sendable {
        case runtimeIntegrityFailed = "runtime.integrity-failed"
        case persistenceDirectoryCreateFailed = "persistence.directory-create-failed"
        case persistenceLoadFailed = "persistence.load-failed"
        case persistenceSaveFailed = "persistence.save-failed"
        case memoryStatisticsReadFailed = "memory.statistics-read-failed"
        case physicalMemoryReadFailed = "memory.physical-read-failed"
        case sipStatusReadFailed = "security.sip-status-read-failed"
        case loginItemUpdateFailed = "settings.login-item-update-failed"
        case selfTestEncodingFailed = "self-test.encoding-failed"
        case selfTestRestoreFailed = "self-test.restore-failed"
        case selfTestReadFailed = "self-test.read-failed"
        case selfTestCleanupFailed = "self-test.cleanup-failed"
        case unsupportedTuningCommand = "security.unsupported-tuning-command"
        case fileTouchFailed = "persistence.file-touch-failed"
        case fileRemoveFailed = "persistence.file-remove-failed"
        case unsafeLaunchdLabel = "process.unsafe-launchd-label"
        case unsafePlistPath = "process.unsafe-plist-path"
        case plistOutsideAllowedRoots = "process.plist-outside-allowed-roots"
        case processScanFailed = "process.scan-failed"
        case processEnumerationFailed = "process.enumeration-failed"
        case processIdentityEnumerationFailed = "process.identity-enumeration-failed"
        case launchdLabelResolutionFailed = "process.launchd-label-resolution-failed"
        case launchdToggleRejected = "process.launchd-toggle-rejected"
        case plistReadFailed = "process.plist-read-failed"
        case privilegeTemporaryFileWriteFailed = "privilege.temporary-file-write-failed"
        case privilegeTemporaryFileCleanupFailed = "privilege.temporary-file-cleanup-failed"
        case privilegeConfigurationFailed = "privilege.configuration-failed"
        case commandPolicyRejected = "security.command-policy-rejected"
        case privilegedCommandPolicyRejected = "security.privileged-command-policy-rejected"
        case mainActorDelayFailed = "runtime.main-actor-delay-failed"
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

    static func error(_ code: Code, category: Category = .general, detail: String? = nil) {
        log(code, detail: detail, using: logger(for: category), level: .error)
    }

    static func warning(_ code: Code, category: Category = .general, detail: String? = nil) {
        log(code, detail: detail, using: logger(for: category), level: .warning)
    }

    static func info(_ code: Code, category: Category = .general, detail: String? = nil) {
        log(code, detail: detail, using: logger(for: category), level: .info)
    }

    private enum Level {
        case error
        case warning
        case info
    }

    private static func log(_ code: Code, detail: String?, using logger: Logger, level: Level) {
        switch (level, detail) {
        case let (.error, .some(detail)):
            logger.error("code=\(code.rawValue, privacy: .public) detail=\(detail, privacy: .private)")
        case (.error, .none):
            logger.error("code=\(code.rawValue, privacy: .public)")
        case let (.warning, .some(detail)):
            logger.warning("code=\(code.rawValue, privacy: .public) detail=\(detail, privacy: .private)")
        case (.warning, .none):
            logger.warning("code=\(code.rawValue, privacy: .public)")
        case let (.info, .some(detail)):
            logger.info("code=\(code.rawValue, privacy: .public) detail=\(detail, privacy: .private)")
        case (.info, .none):
            logger.info("code=\(code.rawValue, privacy: .public)")
        }
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
