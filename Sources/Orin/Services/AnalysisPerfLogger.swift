import Darwin
import Foundation

/// Lightweight performance logger for the post-call analysis pipeline.
///
/// Writes timestamped `[AnalysisPerf]` lines to:
/// - stdout (visible in Console.app filtered by process)
/// - ~/Library/Application Support/Orin/Logs/analysis-YYYY-MM-DD-HHMMSS.log
///
/// A new log file is opened on the first `start()` call after `finish()` or app launch.
/// The file stays open until `finish()` is called so all analysis phases are captured
/// even though recording has already ended (SessionLogger is closed at that point).
enum AnalysisPerfLogger {

    // MARK: - State

    private static var fileHandle: FileHandle?
    private static let queue = DispatchQueue(label: "com.orin.analysis-perf-logger", qos: .utility)
    private static var startTime: ContinuousClock.Instant?

    // MARK: - Session lifecycle

    /// Opens a new analysis log file and records the start event.
    /// - Parameters:
    ///   - meetingID: Short suffix for the meeting UUID (first 8 chars).
    ///   - chars: Total transcript character count.
    ///   - words: Total transcript word count.
    ///   - model: AI model name (e.g. "mistral:latest").
    static func start(meetingID: String, chars: Int, words: Int, model: String) {
        queue.async {
            openLogFileIfNeeded()
            startTime = .now
            write("START meeting=\(meetingID) chars=\(chars) words=\(words) model=\(model) ramMB=\(currentRAMMB())")
        }
    }

    /// Records a named sub-phase completion.
    static func phase(_ label: String, duration: TimeInterval) {
        queue.async {
            write(String(format: "%@ duration=%.2fs ramMB=%d", label, duration, currentRAMMB()))
        }
    }

    /// Records a raw message (e.g. "Ollama request started").
    static func event(_ message: String) {
        queue.async {
            write(message)
        }
    }

    /// Records the COMPLETE event and closes the log file.
    static func finish(totalDuration: TimeInterval) {
        queue.async {
            write(String(format: "COMPLETE total=%.1fs peakRAM=%dMB", totalDuration, currentRAMMB()))
            fileHandle?.closeFile()
            fileHandle = nil
            startTime = nil
        }
    }

    // MARK: - Helpers

    private static func write(_ message: String) {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let line = "[\(ts)] [AnalysisPerf] \(message)\n"
        print("[AnalysisPerf] \(message)")
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    private static func openLogFileIfNeeded() {
        guard fileHandle == nil else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "analysis-\(formatter.string(from: Date())).log"
        let logsDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Orin/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    // MARK: - RAM measurement

    /// Returns the current process resident memory in megabytes.
    static func currentRAMMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size) / 1_048_576
    }
}
