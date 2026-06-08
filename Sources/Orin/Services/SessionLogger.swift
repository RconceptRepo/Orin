import Foundation
import OSLog

// MARK: - SessionLogger

/// Writes timestamped diagnostic entries to a per-session log file AND the
/// unified OS log (visible in Console.app filtered by subsystem
/// "com.clavrit.orin").
///
/// **Log file location:** ~/Library/Application Support/Orin/Logs/session-YYYY-MM-DD-HHmmss.log
///
/// Usage:
///   SessionLogger.shared.startSession()   // call at recording start
///   SessionLogger.shared.log("[Mic] ...")  // call anywhere on MainActor
///   SessionLogger.shared.endSession()     // call at recording stop
///
/// `startSession()` is idempotent — if a session is already active the call
/// is a no-op, so both RecordingService and SystemAudioCaptureService can
/// call it safely without coordination.
@MainActor
final class SessionLogger {

    static let shared = SessionLogger()

    private let osLog = Logger(subsystem: "com.clavrit.orin", category: "Session")
    private var fileHandle: FileHandle?

    /// Absolute path of the current log file, or nil between sessions.
    private(set) var currentLogPath: String?

    private init() {}

    // MARK: - Session control

    func startSession() {
        guard fileHandle == nil else { return }

        guard let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Orin/Logs", isDirectory: true)
        else { return }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "session-\(formatter.string(from: Date())).log"
        let url = dir.appendingPathComponent(name)

        // Create empty file so FileHandle can open it.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = FileHandle(forUpdatingAtPath: url.path)
        currentLogPath = url.path

        let header = "=== Orin Session Log ===\nDate: \(Date())\nLog:  \(url.path)\n\n"
        writeRaw(header)

        osLog.info("session log started: \(url.path, privacy: .public)")
        print("[SessionLogger] \(url.path)")
    }

    func endSession() {
        writeRaw("\n=== Session ended: \(Date()) ===\n")
        fileHandle?.closeFile()
        fileHandle = nil
    }

    // MARK: - Logging

    /// Writes a timestamped line to both the log file and the OS unified log.
    func log(_ message: String) {
        let ts = String(format: "%.3f", Date().timeIntervalSinceReferenceDate)
        writeRaw("[\(ts)] \(message)\n")
        osLog.info("\(message, privacy: .public)")
    }

    // MARK: - Private

    private func writeRaw(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }
}
