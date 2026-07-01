import Foundation

/// A point-in-time snapshot of system state captured at inference execution time.
///
/// Written into every `InferenceTelemetryRecord` so post-hoc analysis can
/// correlate inference latency with thermal state, power mode, and hardware profile.
/// All reads are synchronous from `ProcessInfo` — no syscalls, no I/O.
struct InferenceSystemSnapshot: Sendable, Codable {

    let thermalState: ThermalStateSnapshot
    let isLowPowerMode: Bool
    /// Installed physical RAM in gibibytes (e.g. 8.0, 16.0, 32.0).
    let physicalMemoryGB: Double
    /// `CFAbsoluteTimeGetCurrent()` at capture time.
    let capturedAt: Double

    // MARK: - Thermal state (Codable-friendly copy)

    /// Mirrors `ProcessInfo.ThermalState` raw values.
    /// Apple's type is not `Codable`, so we duplicate the cases.
    enum ThermalStateSnapshot: Int, Sendable, Codable {
        case nominal  = 0
        case fair     = 1
        case serious  = 2
        case critical = 3

        init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal:   self = .nominal
            case .fair:      self = .fair
            case .serious:   self = .serious
            case .critical:  self = .critical
            @unknown default: self = .nominal
            }
        }
    }

    // MARK: - Factory

    /// Captures current system state synchronously. Safe to call from any actor.
    static func capture() -> InferenceSystemSnapshot {
        InferenceSystemSnapshot(
            thermalState:     ThermalStateSnapshot(ProcessInfo.processInfo.thermalState),
            isLowPowerMode:   ProcessInfo.processInfo.isLowPowerModeEnabled,
            physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            capturedAt:       CFAbsoluteTimeGetCurrent()
        )
    }
}
