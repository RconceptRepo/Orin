import Foundation
import OSLog

private let log = Logger(subsystem: "com.clavrit.orin", category: "InferenceResourceMonitor")

/// Monitors system conditions that affect inference scheduling.
///
/// `InferenceScheduler` calls `shouldDefer(priority:)` before dequeuing each job.
/// The monitor tracks recording state via `NotificationCenter` (posted by
/// `RecordingService`) and reads thermal / power state from `ProcessInfo` at
/// decision time (cheap, synchronous).
///
/// Rules:
/// - `.critical` priority is **never** deferred.
/// - `.userVisible` is deferred only under `.critical` thermal state.
/// - `.background` and `.maintenance` are deferred during recording,
///   `.serious`/`.critical` thermal states, or low-power mode.
actor InferenceResourceMonitor {

    private var isRecordingActive: Bool = false

    // MARK: - Init

    init() {
        Task { await self.startObserving() }
    }

    // MARK: - Decision

    /// Returns `true` when the given priority should wait before executing.
    func shouldDefer(priority: InferencePriority) -> Bool {
        if priority == .critical { return false }

        // Defer background/maintenance during active recording sessions
        if isRecordingActive && priority <= .background { return true }

        // Thermal state — ProcessInfo caches this; reading is O(1)
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            return priority < .critical   // everything except critical
        case .serious:
            return priority <= .background
        default:
            break
        }

        // Low-power mode: protect battery; defer background and below
        if ProcessInfo.processInfo.isLowPowerModeEnabled && priority <= .background {
            return true
        }

        return false
    }

    // MARK: - State updates (called by notification observers)

    func setRecordingActive(_ active: Bool) {
        isRecordingActive = active
        log.debug("Recording active → \(active); scheduler will \(active ? "defer background jobs" : "resume")")
    }

    // MARK: - Observation

    private func startObserving() {
        NotificationCenter.default.addObserver(
            forName: .recordingActiveChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let active = notification.userInfo?["active"] as? Bool ?? false
            Task { await self?.setRecordingActive(active) }
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted by `RecordingService` when recording starts or stops.
    ///
    /// `userInfo` key `"active"`: `Bool` — `true` when recording begins,
    /// `false` when recording ends (phase reaches `.idle`).
    static let recordingActiveChanged = Notification.Name("com.clavrit.orin.recordingActiveChanged")
}
