import Foundation

// MARK: - InferenceRequest

/// A single inference job submitted to InferenceWorker.
///
/// Carries everything the worker needs to route, execute, and track the request.
/// `Sendable` so it can be captured across actor and Task boundaries safely.
struct InferenceRequest: Sendable {
    let id: UUID
    /// Associates the request with a meeting so active jobs can be cancelled by ID.
    let meetingID: UUID?
    let prompt: String
    let maxTokens: Int

    init(
        id: UUID = UUID(),
        meetingID: UUID? = nil,
        prompt: String,
        maxTokens: Int = 1500
    ) {
        self.id = id
        self.meetingID = meetingID
        self.prompt = prompt
        self.maxTokens = maxTokens
    }
}

// MARK: - InferenceResponse

/// The result of a completed inference job.
///
/// Always produced by `InferenceWorker`; callers never interact with providers directly.
struct InferenceResponse: Sendable {
    let requestID: UUID
    let text: String
    let providerName: String
    /// `true` when any cloud provider was used because Ollama was unavailable or failed.
    let fallbackUsed: Bool
    let telemetry: InferenceTelemetryRecord
}

// MARK: - InferenceError

enum InferenceError: Error, Sendable {
    case queueFull(depth: Int)
    case circuitOpen
    case allProvidersFailed
    case timeout
}

// MARK: - InferenceWorkerHealth

/// Coarse health classification for InferenceWorker.
///
/// The worker recomputes this after every state change.
/// Future: bridge to `@Observable` wrapper so the menu bar / settings can react.
enum InferenceWorkerHealth: Equatable, Sendable {
    /// Idle or processing within normal parameters.
    case healthy
    /// Jobs are queued; at maximum active concurrency.
    case busy(queueDepth: Int)
    /// Circuit breaker has opened; primary provider is bypassed.
    case degraded(reason: String)
    /// All providers failed or are unreachable.
    case unavailable
}

// MARK: - InferenceTelemetryRecord

/// Per-request structured performance record.
///
/// Accumulated by `InferenceWorker` and available via `telemetry` for diagnostics.
/// Corresponds to the telemetry specification in Doc 14 §11.
struct InferenceTelemetryRecord: Sendable {
    let requestID: UUID
    let meetingID: UUID?
    let providerName: String
    let modelName: String

    /// `CFAbsoluteTimeGetCurrent()` at enqueue time.
    let queuedAtAbsTime: Double
    /// `CFAbsoluteTimeGetCurrent()` when the job started executing.
    let dequeuedAtAbsTime: Double
    /// `CFAbsoluteTimeGetCurrent()` when the job completed.
    let completedAtAbsTime: Double

    let promptCharCount: Int
    let responseCharCount: Int
    let retryCount: Int
    let timeoutCount: Int
    let wasCancelled: Bool
    let completionReason: CompletionReason

    var queueWaitSeconds: Double { dequeuedAtAbsTime - queuedAtAbsTime }
    var inferenceSeconds: Double { completedAtAbsTime - dequeuedAtAbsTime }

    enum CompletionReason: String, Sendable {
        case success
        case fallback         // cloud provider used instead of Ollama
        case allFailed
        case cancelled
        case circuitOpen      // request rejected immediately; no HTTP sent
        case queueFull        // request rejected at admission
        case timeout
    }
}

// MARK: - CircuitBreaker

/// Three-state circuit breaker embedded in InferenceWorker.
///
/// Lives inside the InferenceWorker actor (not itself an actor) — the actor's
/// isolation provides the serial access guarantee.
///
/// State machine:
///   Closed  — (failureThreshold consecutive failures) → Open
///   Open    — (openTimeout expires)                   → HalfOpen
///   HalfOpen — (success)                              → Closed
///   HalfOpen — (failure)                              → Open
struct CircuitBreaker: Sendable {

    enum State: Equatable, Sendable {
        case closed
        case open(until: ContinuousClock.Instant)
        case halfOpen
    }

    private(set) var state: State = .closed
    private var consecutiveFailures: Int = 0

    let failureThreshold: Int   // default 3
    let openTimeout: Duration   // default 30 s

    init(failureThreshold: Int = 3, openTimeout: Duration = .seconds(30)) {
        self.failureThreshold = failureThreshold
        self.openTimeout = openTimeout
    }

    /// Returns `true` when the breaker allows a new request through.
    /// Transitions `Open → HalfOpen` when the cooldown has elapsed.
    mutating func allowsRequest() -> Bool {
        switch state {
        case .closed:   return true
        case .halfOpen: return true
        case .open(let until):
            if ContinuousClock.now >= until {
                state = .halfOpen
                return true
            }
            return false
        }
    }

    mutating func recordSuccess() {
        switch state {
        case .closed:   consecutiveFailures = 0
        case .halfOpen:
            state = .closed
            consecutiveFailures = 0
        case .open:     break
        }
    }

    mutating func recordFailure() {
        consecutiveFailures += 1
        switch state {
        case .closed:
            if consecutiveFailures >= failureThreshold {
                state = .open(until: ContinuousClock.now + openTimeout)
            }
        case .halfOpen:
            state = .open(until: ContinuousClock.now + openTimeout)
        case .open:
            break
        }
    }

    mutating func forceClose() {
        state = .closed
        consecutiveFailures = 0
    }

    var isOpen: Bool {
        if case .open(let until) = state, ContinuousClock.now < until { return true }
        return false
    }

    var stateDescription: String {
        switch state {
        case .closed:   return "closed (\(consecutiveFailures)/\(failureThreshold) failures)"
        case .open:     return "open (cooldown)"
        case .halfOpen: return "half-open"
        }
    }
}
