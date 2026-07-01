import Foundation

/// Computes the recommended maximum number of concurrent inference jobs.
///
/// Local providers (Ollama) always return 1 — GPU inference is inherently serial.
/// Cloud providers can scale to 2 concurrent jobs on high-RAM machines under
/// favourable thermal and power conditions.
///
/// All reads are synchronous from `ProcessInfo`; no internal state is cached.
/// `InferenceScheduler` queries this after each job completes.
struct InferenceConcurrencyController: Sendable {

    /// Recommended maximum concurrent jobs for the named provider.
    ///
    /// - Parameter providerName: The value of `InferenceProvider.name`.
    func recommendedMaxJobs(for providerName: String) -> Int {
        let isLocal = providerName.lowercased().contains("ollama")
        if isLocal { return 1 }  // GPU inference is always single-threaded

        // Thermal emergency — serialize everything to protect the device
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical || thermal == .serious { return 1 }

        // Battery conservation: keep background work minimal
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 1 }

        // Scale cloud concurrency with available RAM.
        // Cloud inference is network-bound; parallelism costs RAM, not CPU.
        let gb = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return gb >= 16 ? 2 : 1
    }
}
