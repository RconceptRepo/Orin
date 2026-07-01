import Foundation
import OSLog
import SwiftData

private let log = Logger(subsystem: "com.clavrit.orin", category: "InferenceScheduler")

// MARK: - SchedulerJob

private struct SchedulerJob {
    let id: UUID
    let request: InferenceRequest
    let priority: InferencePriority
    let continuation: CheckedContinuation<InferenceResponse, Error>
    let enqueuedAt: Double              // CFAbsoluteTimeGetCurrent()
    let queueDepthAtSubmission: Int     // total jobs in scheduler at enqueue time
}

// MARK: - InferenceScheduler

/// Resource-aware priority scheduler layered above `InferenceWorker`.
///
/// # Architecture
///
/// ```
/// Caller → InferenceScheduler.infer()  (decides WHEN)
///              ↓ priority queue + resource gating
///          InferenceWorker.infer()      (decides HOW)
///              ↓ provider cascade, circuit breaker, telemetry
///          InferenceProvider.infer()
/// ```
///
/// # Priority queue
///
/// Jobs are sorted descending by `InferencePriority`. Within the same priority,
/// FIFO order is preserved. `critical` always executes first; `maintenance`
/// only when the system is idle.
///
/// # Resource gating
///
/// Before dequeuing each job, the scheduler queries `InferenceResourceMonitor`.
/// Background and maintenance jobs are deferred during:
///   - Active recording sessions
///   - `.serious` or `.critical` thermal states
///   - Low-power mode (battery conservation)
///
/// Deferred drains are retried every 15 seconds. New job submissions cancel
/// any pending retry and trigger an immediate re-evaluation.
///
/// # Crash-durable persistence
///
/// Every submitted job is written to SwiftData before entering the in-memory
/// queue. Status transitions from `queued → running → completed | failed` are
/// persisted asynchronously on the `@MainActor`. On the next app launch, call
/// `recoverInterruptedJobs()` to mark orphaned jobs and get the affected
/// meeting IDs for re-analysis.
actor InferenceScheduler: Service {

    // MARK: - Subsystems

    private let worker: InferenceWorker
    let resourceMonitor: InferenceResourceMonitor
    private let concurrencyController: InferenceConcurrencyController
    /// SwiftData container for job persistence. `nil` in tests (no persistence).
    private let container: ModelContainer?

    // MARK: - Queue state

    private var queue: [SchedulerJob] = []
    private var activeCount: Int = 0
    private var deferralRetryTask: Task<Void, Never>?

    // MARK: - Init

    /// Create a scheduler with the given provider list and optional persistence container.
    ///
    /// - Parameters:
    ///   - providers: Inference providers in cascade order (same as `InferenceWorker`).
    ///   - container: SwiftData `ModelContainer` for job durability. Pass `nil` in tests.
    init(providers: [any InferenceProvider], container: ModelContainer? = nil) {
        self.worker               = InferenceWorker(providers: providers)
        self.resourceMonitor      = InferenceResourceMonitor()
        self.concurrencyController = InferenceConcurrencyController()
        self.container            = container
    }

    // MARK: - Public API

    /// Submit an inference job and suspend until a provider returns a result.
    ///
    /// The job is inserted at the correct priority position in the queue and
    /// written to SwiftData for crash durability. Execution begins when both
    /// a worker slot is available and system resources allow.
    func infer(_ request: InferenceRequest) async throws -> InferenceResponse {
        let depth = queue.count + activeCount
        // Enrich the request with scheduler-side metadata for telemetry
        let enriched = InferenceRequest(
            id:                    request.id,
            meetingID:             request.meetingID,
            prompt:                request.prompt,
            maxTokens:             request.maxTokens,
            priority:              request.priority,
            schedulerQueueDepth:   depth
        )
        return try await withCheckedThrowingContinuation { continuation in
            let job = SchedulerJob(
                id:                     enriched.id,
                request:                enriched,
                priority:               enriched.priority,
                continuation:           continuation,
                enqueuedAt:             CFAbsoluteTimeGetCurrent(),
                queueDepthAtSubmission: depth
            )
            insertByPriority(job)
            persistJob(enriched)
            drain()
        }
    }

    /// Cancel all queued and active jobs associated with a specific meeting.
    func cancelJobs(for meetingID: UUID) async {
        let toCancel = queue.filter { $0.request.meetingID == meetingID }
        queue.removeAll { $0.request.meetingID == meetingID }
        for job in toCancel {
            job.continuation.resume(throwing: CancellationError())
        }
        await worker.cancelJobs(for: meetingID)
    }

    /// Cancel every pending and active job.
    func cancelAll() async {
        let all = queue
        queue.removeAll()
        for job in all { job.continuation.resume(throwing: CancellationError()) }
        await worker.cancelAll()
    }

    // MARK: - Health and telemetry (forwarded to InferenceWorker)

    var health: InferenceWorkerHealth {
        get async { await worker.health }
    }

    var telemetryLog: [InferenceTelemetryRecord] {
        get async { await worker.telemetryLog }
    }

    // MARK: - Crash recovery

    /// Marks interrupted jobs from a previous session as `.recovered`.
    ///
    /// Call once at app startup before any new jobs are submitted. Jobs that were
    /// in `.queued` or `.running` state when the process died are transitioned
    /// to `.recovered` so the meeting intelligence layer can detect and re-trigger
    /// interrupted analyses.
    func recoverInterruptedJobs() async {
        guard let container else { return }
        let recoveredCount: Int = await MainActor.run {
            let ctx = container.mainContext
            let statusQueued  = InferenceJobPersistenceStatus.queued.rawValue
            let statusRunning = InferenceJobPersistenceStatus.running.rawValue
            var descriptor = FetchDescriptor<PersistentInferenceJob>(
                predicate: #Predicate { $0.statusRaw == statusQueued || $0.statusRaw == statusRunning }
            )
            descriptor.fetchLimit = 200
            let orphans = (try? ctx.fetch(descriptor)) ?? []
            let recoveredRaw = InferenceJobPersistenceStatus.recovered.rawValue
            for o in orphans { o.statusRaw = recoveredRaw }
            try? ctx.save()
            return orphans.count
        }
        if recoveredCount > 0 {
            log.warning("Recovered \(recoveredCount) interrupted inference job(s) from previous session")
        }
    }

    // MARK: - Priority insertion

    private func insertByPriority(_ job: SchedulerJob) {
        // Insert before the first job with strictly lower priority.
        // This preserves FIFO ordering within the same priority tier.
        if let idx = queue.firstIndex(where: { $0.priority < job.priority }) {
            queue.insert(job, at: idx)
        } else {
            queue.append(job)
        }
    }

    // MARK: - Drain

    private func drain() {
        guard !queue.isEmpty, activeCount < 1 else { return }
        // Note: maxConcurrent is currently fixed at 1 (matches InferenceWorker default).
        // Future: query concurrencyController.recommendedMaxJobs(for: frontProvider)
        // when multi-provider parallel execution is enabled.

        let frontPriority = queue[0].priority
        Task {
            let shouldWait = await resourceMonitor.shouldDefer(priority: frontPriority)
            if shouldWait {
                log.debug("Deferring queue (priority=\(frontPriority.rawValue)); retry in 15s")
                await self.scheduleDeferralRetry()
            } else {
                await self.dequeueAndLaunch()
            }
        }
    }

    private func dequeueAndLaunch() async {
        // Re-check after the async resource check — another drain may have dequeued already
        guard !queue.isEmpty, activeCount < 1 else { return }

        // A successful dequeue cancels any pending deferral retry
        deferralRetryTask?.cancel()
        deferralRetryTask = nil

        let job = queue.removeFirst()
        activeCount += 1
        log.debug("Scheduler executing job \(job.id) priority=\(job.priority.rawValue) queueRemaining=\(self.queue.count)")
        updatePersistenceStatus(id: job.id, newStatus: .running)

        Task { await self.executeJob(job) }
    }

    private func executeJob(_ job: SchedulerJob) async {
        do {
            let response = try await worker.infer(job.request)
            finishJob(job, result: .success(response))
        } catch {
            finishJob(job, result: .failure(error))
        }
    }

    private func finishJob(_ job: SchedulerJob, result: Result<InferenceResponse, Error>) {
        activeCount -= 1
        switch result {
        case .success(let response):
            updatePersistenceStatus(id: job.id, newStatus: .completed)
            job.continuation.resume(returning: response)
        case .failure(let err):
            updatePersistenceStatus(id: job.id, newStatus: .failed, error: err.localizedDescription)
            job.continuation.resume(throwing: err)
        }
        drain()
    }

    // MARK: - Deferral retry

    private func scheduleDeferralRetry() {
        guard deferralRetryTask == nil else { return }
        deferralRetryTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            deferralRetryTask = nil
            drain()
        }
    }

    // MARK: - Persistence (fire-and-forget on @MainActor)

    private func persistJob(_ request: InferenceRequest) {
        guard let container else { return }
        let id       = request.id
        let mID      = request.meetingID
        let prompt   = request.prompt
        let tokens   = request.maxTokens
        let priority = request.priority
        Task { @MainActor [container] in
            let record = PersistentInferenceJob(
                id: id, meetingID: mID,
                prompt: prompt, maxTokens: tokens,
                priority: priority
            )
            container.mainContext.insert(record)
            try? container.mainContext.save()
        }
    }

    private func updatePersistenceStatus(
        id: UUID,
        newStatus: InferenceJobPersistenceStatus,
        error: String? = nil
    ) {
        guard let container else { return }
        let statusRaw = newStatus.rawValue
        let errMsg    = error
        Task { @MainActor [container] in
            let ctx = container.mainContext
            var descriptor = FetchDescriptor<PersistentInferenceJob>(
                predicate: #Predicate { $0.jobID == id }
            )
            descriptor.fetchLimit = 1
            guard let record = try? ctx.fetch(descriptor).first else { return }
            record.statusRaw = statusRaw
            if newStatus == .running   { record.startedAt   = Date() }
            if newStatus == .completed || newStatus == .failed { record.completedAt = Date() }
            if let e = errMsg          { record.lastError   = e }
            try? ctx.save()
        }
    }
}
