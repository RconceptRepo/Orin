import Foundation

/// Scheduling priority for inference jobs submitted to InferenceScheduler.
///
/// Higher-priority jobs execute before lower-priority jobs waiting in the queue.
/// Within the same priority, submission order (FIFO) is preserved.
enum InferencePriority: Int, Comparable, Sendable, Codable {
    /// Periodic housekeeping, health pings — run only when the system is idle.
    case maintenance = 0
    /// Background AI work (auto-analysis, folder summaries) — deferred during
    /// active recording and under thermal or memory pressure.
    case background = 1
    /// Work the user is actively waiting for (on-demand re-analysis, summary views).
    case userVisible = 2
    /// Time-critical work that must run immediately regardless of system state.
    case critical = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
