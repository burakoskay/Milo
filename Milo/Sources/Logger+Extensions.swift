import Foundation
import os

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.monomacaw.milo"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let memory = Logger(subsystem: subsystem, category: "memory")
    static let process = Logger(subsystem: subsystem, category: "process")
    static let license = Logger(subsystem: subsystem, category: "license")
    static let privilege = Logger(subsystem: subsystem, category: "privilege")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let stats = Logger(subsystem: subsystem, category: "stats")
    static let whitelist = Logger(subsystem: subsystem, category: "whitelist")
    static let sip = Logger(subsystem: subsystem, category: "sip")
    static let selfTest = Logger(subsystem: subsystem, category: "selfTest")
}
