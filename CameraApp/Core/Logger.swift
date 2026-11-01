import Foundation
import os

/// Centralized logging for CameraApp. Uses `os_log` so output appears in
/// Console.app and `log collect` on device; levels are cheap no-ops when the
/// OS isn't listening.
enum Logger {
    private init() {}

    private static let subsystem = "com.jaca.cameraapp"

    private static let log = OSLog(subsystem: subsystem, category: "camera")
    private static let pipelineLog = OSLog(subsystem: subsystem, category: "pipeline")
    private static let uiLog = OSLog(subsystem: subsystem, category: "ui")
    private static let saveLog = OSLog(subsystem: subsystem, category: "save")

    /// Information-level events (session start/stop, mode switches, saves).
    static func info(_ message: String, category: OSLog = log) {
        os_log("%{public}@", log: category, type: .info, message)
    }

    /// Errors that should be investigated (hardware failures, encode failures).
    static func error(_ message: String, category: OSLog = log) {
        os_log("%{public}@", log: category, type: .error, message)
    }

    /// Debug-level events (frame drops, pipeline stage timing).
    static func debug(_ message: String, category: OSLog = log) {
        os_log("%{public}@", log: category, type: .debug, message)
    }

    // MARK: - Categorized helpers

    static func session(_ message: String) { info(message, category: log) }
    static func pipeline(_ message: String) { debug(message, category: pipelineLog) }
    static func ui(_ message: String) { debug(message, category: uiLog) }
    static func save(_ message: String) { info(message, category: saveLog) }
    static func fail(_ message: String) { error(message, category: log) }
}
