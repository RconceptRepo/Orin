import Foundation
import SwiftData

// MARK: - Persistence status

/// Lifecycle status of a durable inference job record.
enum InferenceJobPersistenceStatus: String, Codable, Sendable {
    case queued    // Entered the in-memory scheduler queue
    case running   // Handed off to InferenceWorker for execution
    case completed // Provider returned a result
    case failed    // All providers exhausted or job was cancelled
    case recovered // Was queued/running when the app crashed; marked on next launch
}

// MARK: - SwiftData model

/// Durable record of an inference job written to SwiftData by `InferenceScheduler`.
///
/// # Lifecycle
///
///   `InferenceScheduler.infer()` writes the record with status `.queued`
///   before appending the job to the in-memory priority queue.
///   Status transitions as the job progresses:
///
///   ```
///   queued → running → completed | failed
///   ```
///
/// # Crash recovery
///
///   On the next app launch, `InferenceScheduler.recoverInterruptedJobs()` finds
///   any records still in `.queued` or `.running` state — jobs that were live
///   when the process died — and marks them `.recovered`. Callers inspect
///   `InferenceScheduler.recoverInterruptedJobs()` to get the affected meeting IDs
///   and re-trigger analysis where appropriate.
@Model
final class PersistentInferenceJob {

    @Attribute(.unique) var jobID: UUID
    var meetingID: UUID?
    var prompt: String
    var maxTokens: Int
    /// Raw value of `InferencePriority` — stored as Int for SwiftData compatibility.
    var priorityRaw: Int
    /// Raw value of `InferenceJobPersistenceStatus` — stored as String.
    var statusRaw: String
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var retryCount: Int
    var lastError: String?

    init(
        id: UUID,
        meetingID: UUID?,
        prompt: String,
        maxTokens: Int,
        priority: InferencePriority
    ) {
        self.jobID       = id
        self.meetingID   = meetingID
        self.prompt      = prompt
        self.maxTokens   = maxTokens
        self.priorityRaw = priority.rawValue
        self.statusRaw   = InferenceJobPersistenceStatus.queued.rawValue
        self.createdAt   = Date()
        self.retryCount  = 0
    }

    // MARK: - Typed accessors

    var priority: InferencePriority {
        InferencePriority(rawValue: priorityRaw) ?? .background
    }

    var status: InferenceJobPersistenceStatus {
        get { InferenceJobPersistenceStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }
}
