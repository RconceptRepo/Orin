import Foundation
import OSLog

private let log = Logger(subsystem: "com.clavrit.orin", category: "InferenceWorker")

// MARK: - Internal job types

private struct PendingJob {
    let id: UUID
    let request: InferenceRequest
    let continuation: CheckedContinuation<InferenceResponse, Error>
    let enqueuedAt: Double   // CFAbsoluteTimeGetCurrent()
}

private struct ActiveJob {
    let id: UUID
    let meetingID: UUID?
    let task: Task<Void, Never>
}

// MARK: - InferenceWorker

/// The single component in the application that dispatches AI inference.
///
/// # Architecture contract
///
/// - **One entry point**: all callers use `infer(_:)`. No code outside this actor
///   may call a provider directly.
/// - **Bounded concurrency**: `maxConcurrentJobs` (default 1) is enforced. All
///   excess jobs are queued and drained automatically as slots free up. Raising the
///   limit in the future requires changing only `maxConcurrentJobs` — no structural
///   changes elsewhere.
/// - **Provider cascade**: providers are tried in declaration order. The circuit
///   breaker for a provider opens after `failureThreshold` consecutive failures and
///   re-closes after `openTimeout` seconds via a half-open probe.
/// - **Cancellation**: `cancelJobs(for:)` drains queued jobs immediately and signals
///   in-flight URLSession requests through Swift's cooperative cancellation.
/// - **No `withTaskGroup`**: the thundering-herd footgun from the old implementation
///   is eliminated. InferenceWorker is the sole authority on how many requests are
///   in flight at any moment.
actor InferenceWorker: Service {

    // MARK: - Configuration

    /// Maximum simultaneous in-flight provider calls.
    ///
    /// Set to 1 for Ollama (single-GPU local inference). Raise via configuration
    /// for cloud providers or multi-GPU setups without changing any other code.
    let maxConcurrentJobs: Int

    /// Maximum number of pending jobs in the queue before new submissions are rejected.
    let maxQueueDepth: Int

    // MARK: - State

    private let providers: [any InferenceProvider]
    private var queue: [PendingJob] = []
    private var activeJobs: [ActiveJob] = []
    private var circuitBreakers: [String: CircuitBreaker] = [:]
    private(set) var telemetryLog: [InferenceTelemetryRecord] = []

    // MARK: - Init

    init(
        providers: [any InferenceProvider],
        maxConcurrentJobs: Int = 1,
        maxQueueDepth: Int = 50
    ) {
        self.providers = providers
        self.maxConcurrentJobs = maxConcurrentJobs
        self.maxQueueDepth = maxQueueDepth
    }

    // MARK: - Public API

    /// Submit a job and await its result.
    ///
    /// Returns when a provider successfully completes the request.
    /// Throws `InferenceError.queueFull` if the queue is at capacity.
    /// Throws `InferenceError.allProvidersFailed` when every provider (and the circuit
    /// breaker for each) has been exhausted.
    /// Propagates `CancellationError` when the calling Task is cancelled or the job
    /// is cancelled via `cancelJobs(for:)`.
    func infer(_ request: InferenceRequest) async throws -> InferenceResponse {
        guard queue.count < maxQueueDepth else {
            log.warning("Queue full (depth=\(self.queue.count)) — rejecting request \(request.id)")
            throw InferenceError.queueFull(depth: queue.count)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let job = PendingJob(
                id: request.id,
                request: request,
                continuation: continuation,
                enqueuedAt: CFAbsoluteTimeGetCurrent()
            )
            queue.append(job)
            drainQueue()
        }
    }

    /// Cancel all queued and active jobs associated with a specific meeting.
    func cancelJobs(for meetingID: UUID) {
        let toCancel = queue.filter { $0.request.meetingID == meetingID }
        queue.removeAll { $0.request.meetingID == meetingID }
        for job in toCancel {
            log.debug("Cancelling queued job \(job.id) (meeting=\(meetingID))")
            job.continuation.resume(throwing: CancellationError())
        }
        for active in activeJobs where active.meetingID == meetingID {
            log.debug("Cancelling active job \(active.id) (meeting=\(meetingID))")
            active.task.cancel()
        }
    }

    /// Cancel every queued and active job regardless of meeting association.
    func cancelAll() {
        let all = queue
        queue.removeAll()
        for job in all {
            job.continuation.resume(throwing: CancellationError())
        }
        for active in activeJobs {
            active.task.cancel()
        }
    }

    /// Force-close all circuit breakers (e.g. when the user taps "Retry" in Settings).
    func resetCircuitBreakers() {
        for key in circuitBreakers.keys {
            circuitBreakers[key]?.forceClose()
        }
    }

    // MARK: - Health

    var health: InferenceWorkerHealth {
        if activeJobs.isEmpty && queue.isEmpty { return .healthy }

        let openProviders = providers.filter { p in
            var breaker = circuitBreakers[p.name, default: CircuitBreaker()]
            return breaker.allowsRequest()
        }
        if openProviders.isEmpty { return .unavailable }

        let anyOpen = circuitBreakers.values.contains { $0.isOpen }
        if anyOpen { return .degraded(reason: "Circuit open on ≥1 provider") }

        return queue.isEmpty ? .healthy : .busy(queueDepth: queue.count)
    }

    // MARK: - Queue drain (sync, runs entirely within actor)

    private func drainQueue() {
        while activeJobs.count < maxConcurrentJobs, !queue.isEmpty {
            let job = queue.removeFirst()
            let task = Task {
                await self.executeJob(job)
            }
            activeJobs.append(ActiveJob(id: job.id, meetingID: job.request.meetingID, task: task))
            log.debug("Dequeued job \(job.id) — active=\(self.activeJobs.count) queued=\(self.queue.count)")
        }
    }

    // MARK: - Job execution (async, can suspend across HTTP calls)

    private func executeJob(_ job: PendingJob) async {
        let dequeuedAt = CFAbsoluteTimeGetCurrent()
        do {
            let response = try await executeProviderCascade(job: job, dequeuedAt: dequeuedAt)
            job.continuation.resume(returning: response)
        } catch {
            job.continuation.resume(throwing: error)
        }
        jobFinished(id: job.id)
    }

    private func jobFinished(id: UUID) {
        activeJobs.removeAll { $0.id == id }
        drainQueue()
    }

    // MARK: - Provider cascade

    private func executeProviderCascade(
        job: PendingJob,
        dequeuedAt: Double
    ) async throws -> InferenceResponse {
        var lastError: Error = InferenceError.allProvidersFailed
        var fallbackUsed = false
        var retryCount = 0
        var timeoutCount = 0

        for provider in providers {
            try Task.checkCancellation()

            // Pre-check provider availability (fast — cached or keychain read)
            guard await provider.isAvailable() else {
                log.debug("Provider \(provider.name) not available — skipping")
                fallbackUsed = true
                continue
            }

            // Consult circuit breaker
            var breaker = circuitBreakers[provider.name, default: CircuitBreaker()]
            guard breaker.allowsRequest() else {
                log.debug("Circuit breaker open for \(provider.name) — skipping")
                circuitBreakers[provider.name] = breaker
                fallbackUsed = true
                continue
            }
            circuitBreakers[provider.name] = breaker

            AnalysisPerfLogger.event("InferenceWorker trying provider=\(provider.name)")

            do {
                let text = try await provider.infer(job.request)
                var b = circuitBreakers[provider.name, default: CircuitBreaker()]
                b.recordSuccess()
                circuitBreakers[provider.name] = b

                let completedAt = CFAbsoluteTimeGetCurrent()
                let telemetry = InferenceTelemetryRecord(
                    requestID:         job.request.id,
                    meetingID:         job.request.meetingID,
                    providerName:      provider.name,
                    modelName:         provider.modelName,
                    queuedAtAbsTime:   job.enqueuedAt,
                    dequeuedAtAbsTime: dequeuedAt,
                    completedAtAbsTime: completedAt,
                    promptCharCount:   job.request.prompt.count,
                    responseCharCount: text.count,
                    retryCount:        retryCount,
                    timeoutCount:      timeoutCount,
                    wasCancelled:      false,
                    completionReason:  fallbackUsed ? .fallback : .success
                )
                telemetryLog.append(telemetry)

                AnalysisPerfLogger.event(
                    String(format: "InferenceWorker SUCCESS provider=%@ queueWait=%.2fs infer=%.2fs responseChars=%d",
                           provider.name,
                           telemetry.queueWaitSeconds,
                           telemetry.inferenceSeconds,
                           text.count)
                )
                log.info("Inference succeeded: provider=\(provider.name) chars=\(text.count)")

                return InferenceResponse(
                    requestID:    job.request.id,
                    text:         text,
                    providerName: provider.name,
                    fallbackUsed: fallbackUsed,
                    telemetry:    telemetry
                )

            } catch is CancellationError {
                let completedAt = CFAbsoluteTimeGetCurrent()
                let telemetry = InferenceTelemetryRecord(
                    requestID:         job.request.id,
                    meetingID:         job.request.meetingID,
                    providerName:      provider.name,
                    modelName:         provider.modelName,
                    queuedAtAbsTime:   job.enqueuedAt,
                    dequeuedAtAbsTime: dequeuedAt,
                    completedAtAbsTime: completedAt,
                    promptCharCount:   job.request.prompt.count,
                    responseCharCount: 0,
                    retryCount:        retryCount,
                    timeoutCount:      timeoutCount,
                    wasCancelled:      true,
                    completionReason:  .cancelled
                )
                telemetryLog.append(telemetry)
                throw CancellationError()

            } catch InferenceError.timeout {
                var b = circuitBreakers[provider.name, default: CircuitBreaker()]
                b.recordFailure()
                circuitBreakers[provider.name] = b
                timeoutCount += 1
                retryCount += 1
                lastError = InferenceError.timeout
                fallbackUsed = true
                log.warning("Provider \(provider.name) timed out — trying next")

            } catch {
                var b = circuitBreakers[provider.name, default: CircuitBreaker()]
                b.recordFailure()
                circuitBreakers[provider.name] = b
                retryCount += 1
                lastError = error
                fallbackUsed = true
                log.warning("Provider \(provider.name) failed: \(error) — trying next")
            }
        }

        // All providers exhausted
        let completedAt = CFAbsoluteTimeGetCurrent()
        let telemetry = InferenceTelemetryRecord(
            requestID:         job.request.id,
            meetingID:         job.request.meetingID,
            providerName:      "none",
            modelName:         "none",
            queuedAtAbsTime:   job.enqueuedAt,
            dequeuedAtAbsTime: dequeuedAt,
            completedAtAbsTime: completedAt,
            promptCharCount:   job.request.prompt.count,
            responseCharCount: 0,
            retryCount:        retryCount,
            timeoutCount:      timeoutCount,
            wasCancelled:      false,
            completionReason:  .allFailed
        )
        telemetryLog.append(telemetry)
        AnalysisPerfLogger.event("InferenceWorker ALL providers failed — analysis will use keyword fallback")
        log.error("All providers failed for request \(job.request.id)")
        throw InferenceError.allProvidersFailed
    }
}
