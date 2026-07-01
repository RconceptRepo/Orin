import Foundation

/// A concrete inference backend.
///
/// Each provider knows how to speak to one AI service endpoint.
/// `InferenceWorker` owns provider selection, retry, circuit-breaking, and
/// concurrency — providers implement only the HTTP mechanics.
///
/// ## Adding a new provider
///
/// 1. Create a `final class YourProvider: InferenceProvider, @unchecked Sendable`
/// 2. Implement `name`, `infer(_:)`, and `isAvailable()`
/// 3. Pass an instance to `InferenceWorker(providers:)` at the composition root
/// 4. Zero architectural changes required elsewhere
protocol InferenceProvider: Sendable {

    /// Human-readable name used in telemetry, logging, and `InferenceResponse.providerName`.
    var name: String { get }

    /// The model identifier this provider will use (for telemetry).
    var modelName: String { get }

    /// Perform inference and return the raw completion text.
    ///
    /// Throws `InferenceError.timeout` when the provider exceeds its own deadline.
    /// Throws `CancellationError` when the calling Task is cancelled (propagated by
    /// URLSession cooperative cancellation).
    /// Other failures propagate as-is so the worker can record them and try the next provider.
    func infer(_ request: InferenceRequest) async throws -> String

    /// Returns `true` when the provider believes it can accept requests right now.
    ///
    /// Called once per job as a fast pre-check before committing to an attempt.
    /// Implementations should be fast (cached result or simple reachability) — this
    /// is NOT a blocking health check; the actual availability is proven by `infer`.
    func isAvailable() async -> Bool
}
