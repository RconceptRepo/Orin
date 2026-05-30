import Foundation
import SwiftData

enum TaskPriority: Int, Codable, Comparable, CaseIterable, Identifiable {
    case p0Critical = 0
    case p1High = 1
    case p2Medium = 2
    case p3Low = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .p0Critical: "P0 Critical"
        case .p1High: "P1 High"
        case .p2Medium: "P2 Medium"
        case .p3Low: "P3 Low"
        }
    }

    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum TaskStatus: String, Codable, CaseIterable {
    case active
    case completed
}

enum SuggestionStatus: String, Codable {
    case pending
    case accepted
    case declined
}

@Model
final class TaskItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var taskDescription: String
    var priorityValue: Int
    var effortEstimateMinutes: Int
    var dueDate: Date?
    var tags: [String]
    var statusValue: String
    var dragOrderIndex: Int
    var isBacklog: Bool
    var triggerDate: Date?
    var createdAt: Date
    var completedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \SubTaskItem.parentTask)
    var subtasks: [SubTaskItem] = []

    @Relationship(inverse: \MeetingItem.tasks)
    var linkedMeeting: MeetingItem?

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityValue) ?? .p3Low }
        set { priorityValue = newValue.rawValue }
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusValue) ?? .active }
        set { statusValue = newValue.rawValue }
    }

    init(
        title: String,
        taskDescription: String = "",
        priority: TaskPriority = .p3Low,
        effortEstimateMinutes: Int = 0,
        dueDate: Date? = nil,
        tags: [String] = [],
        isBacklog: Bool = false,
        triggerDate: Date? = nil,
        dragOrderIndex: Int = 0
    ) {
        id = UUID()
        self.title = title
        self.taskDescription = taskDescription
        priorityValue = priority.rawValue
        self.effortEstimateMinutes = effortEstimateMinutes
        self.dueDate = dueDate
        self.tags = tags
        statusValue = TaskStatus.active.rawValue
        self.dragOrderIndex = dragOrderIndex
        self.isBacklog = isBacklog
        self.triggerDate = triggerDate
        createdAt = Date()
    }
}

@Model
final class SubTaskItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var isCompleted: Bool
    var sortIndex: Int
    var parentTask: TaskItem?

    init(title: String, isCompleted: Bool = false, sortIndex: Int = 0) {
        id = UUID()
        self.title = title
        self.isCompleted = isCompleted
        self.sortIndex = sortIndex
    }
}

@Model
final class MeetingItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var date: Date
    var durationSeconds: TimeInterval
    var participants: [String]
    var transcript: String
    var summary: String
    var decisions: [String]
    var actionItems: [String]
    var suggestedTaskTitles: [String]
    var acceptedSuggestedTaskTitles: [String]
    var tags: [String]
    var folderID: UUID?
    var externalEventIdentifier: String?
    var recordingDeletedAt: Date?
    var transcriptDeletedAt: Date?
    var deletedAt: Date?
    /// Path to the locally-recorded audio file for this meeting, if any.
    var audioFilePath: String?

    // MARK: - AI analysis fields (added in AI pipeline upgrade)

    /// Detected meeting type (e.g. "Standup", "Sales Call"). Empty = unclassified.
    var meetingType: String = ""
    /// Unresolved questions raised during the meeting.
    var openQuestions: [String] = []
    /// Risks or concerns identified.
    var risks: [String] = []
    /// External dependencies or blockers mentioned.
    var dependencies: [String] = []
    /// JSON-encoded [ActionItemRecord] — structured action items with owner/priority/due.
    /// Nil when no structured analysis has been run.
    var structuredActionItemsJSON: String?
    /// JSON-encoded MeetingKnowledgeSnapshot — compact representation for folder intelligence.
    /// Updated every time analysis completes. Used instead of raw transcript in folder summaries.
    var meetingKnowledgeJSON: String?

    @Relationship(deleteRule: .cascade)
    var commitments: [CommitmentItem] = []

    var tasks: [TaskItem] = []

    /// Decodes and returns structured action items from `structuredActionItemsJSON`.
    var structuredActionItems: [ActionItemRecord] {
        guard let json = structuredActionItemsJSON,
              let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([ActionItemRecord].self, from: data)
        else { return [] }
        return items
    }

    /// Decodes and returns the compact knowledge snapshot used by folder intelligence.
    var decodedKnowledgeSnapshot: MeetingKnowledgeSnapshot? {
        guard let json = meetingKnowledgeJSON,
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(MeetingKnowledgeSnapshot.self, from: data)
    }

    /// Effective end date for meeting classification.
    ///
    /// Uses a 1-hour default when `durationSeconds` is zero (matches the
    /// `isMeetingNow` logic in `UpcomingMeetingItemRow`).
    var endDate: Date {
        date.addingTimeInterval(durationSeconds > 0 ? durationSeconds : 3600)
    }

    /// `true` when the meeting has not yet fully ended (start ≤ now < endDate).
    var isInProgress: Bool {
        let now = Date()
        return date <= now && endDate > now
    }

    init(title: String, date: Date = Date(), durationSeconds: TimeInterval = 0) {
        id = UUID()
        self.title = title
        self.date = date
        self.durationSeconds = durationSeconds
        participants = []
        transcript = ""
        summary = ""
        decisions = []
        actionItems = []
        suggestedTaskTitles = []
        acceptedSuggestedTaskTitles = []
        tags = []
    }
}

// MARK: - MeetingType

/// Classifiable meeting categories used for context-aware AI analysis.
/// Raw values are human-readable labels shown in the UI.
enum MeetingType: String, CaseIterable, Codable {
    case salesCall       = "Sales Call"
    case discoveryCall   = "Discovery Call"
    case standup         = "Standup"
    case sprintPlanning  = "Sprint Planning"
    case interview       = "Interview"
    case customerSupport = "Customer Support"
    case productReview   = "Product Review"
    case executiveReview = "Executive Review"
    case general         = "General Meeting"

    /// SF Symbol name for displaying the meeting type in the UI.
    var icon: String {
        switch self {
        case .salesCall:       "chart.line.uptrend.xyaxis"
        case .discoveryCall:   "magnifyingglass"
        case .standup:         "person.3"
        case .sprintPlanning:  "calendar.badge.plus"
        case .interview:       "person.crop.square"
        case .customerSupport: "headphones"
        case .productReview:   "checkmark.rectangle"
        case .executiveReview: "building.2"
        case .general:         "video"
        }
    }
}

// MARK: - ActionItemRecord

/// Structured action item extracted from a meeting transcript by AI.
/// Stored as JSON in `MeetingItem.structuredActionItemsJSON`.
struct ActionItemRecord: Codable, Identifiable {
    var id: UUID
    /// Person responsible — "Team" when no specific assignee is mentioned.
    var owner: String
    /// Clear imperative description of the task.
    var task: String
    /// Urgency level: "High", "Medium", "Low", or "Unknown".
    var priority: String
    /// Natural-language due date ("Friday", "End of week") or "" when not mentioned.
    var dueDateText: String
    /// Original line(s) from the transcript that this item was extracted from.
    var rawText: String

    init(owner: String, task: String, priority: String = "Medium",
         dueDateText: String = "", rawText: String = "") {
        id           = UUID()
        self.owner   = owner
        self.task    = task
        self.priority = priority
        self.dueDateText = dueDateText
        self.rawText = rawText
    }
}

// MARK: - MeetingKnowledgeSnapshot
//
// Compact, pre-structured representation of a meeting's analysis results.
// Built from MeetingItem fields after analysis completes and stored as JSON
// in MeetingItem.meetingKnowledgeJSON.
//
// Used by FolderSummaryService instead of raw transcripts, which reduces:
//   - Token usage (structured data is 10-50× more compact than transcript)
//   - API latency (less text to send)
//   - Hallucination risk (AI sees structured facts, not raw speech)

struct MeetingKnowledgeSnapshot: Codable {
    var meetingId: UUID
    var title: String
    var date: Date
    var meetingType: String
    var summary: String
    var decisions: [String]
    var openQuestions: [String]
    var risks: [String]
    var dependencies: [String]
    var commitments: [String]
    var actionItems: [String]                       // flat strings
    var structuredActionItems: [ActionItemRecord]
    var durationSeconds: TimeInterval
    var participants: [String]

    /// Creates a snapshot from the current state of a MeetingItem.
    init(from meeting: MeetingItem) {
        meetingId             = meeting.id
        title                 = meeting.title
        date                  = meeting.date
        meetingType           = meeting.meetingType
        summary               = meeting.summary
        decisions             = meeting.decisions
        openQuestions         = meeting.openQuestions
        risks                 = meeting.risks
        dependencies          = meeting.dependencies
        commitments           = meeting.commitments.map(\.title)
        actionItems           = meeting.actionItems
        structuredActionItems = meeting.structuredActionItems
        durationSeconds       = meeting.durationSeconds
        participants          = meeting.participants
    }
}

// MARK: - TranscriptChunk

/// Granular, per-update transcript record used for crash-safe reconstruction.
///
/// A chunk is written on every `updateMic` / `updateParticipant` call that
/// produces meaningful new content (≥ 10-character growth).  On orphan
/// recovery, `TranscriptStore` uses the latest chunk per speaker as an
/// additional reconstruction candidate beyond the UserDefaults backup.
@Model
final class TranscriptChunk {
    @Attribute(.unique) var id: UUID
    /// The `MeetingItem.id` this chunk belongs to.
    var meetingId: UUID
    /// Wall-clock time the chunk was written.
    var timestamp: Date
    /// "mic" for the local speaker; "participant" for system-audio speaker.
    var speaker: String
    /// Full labeled transcript text for this speaker at this point in time.
    var text: String

    init(meetingId: UUID, speaker: String, text: String) {
        id = UUID()
        self.meetingId = meetingId
        self.timestamp = Date()
        self.speaker = speaker
        self.text = text
    }
}

// MARK: - TranscriptSegment
//
// Conversation-timeline layer built from TranscriptChunks at finalization.
//
// Each segment is a single speaker's DELTA text at a specific wall-clock
// timestamp — unlike TranscriptChunk (full accumulated text, crash recovery),
// TranscriptSegment holds only the new content for that time window.
//
// Ordering segments by timestamp produces the interleaved conversation view:
//   [00:03] Me: Hello everyone.
//   [00:10] Participant: Good morning.
//   [00:18] Me: Let's get started.
//
// The `source` field ("mic"/"participant") tracks physical audio origin and
// is preserved for future speaker identification — a SpeakerIdentificationProvider
// can remap `speakerLabel` to "Speaker 1", "Speaker 2", etc. without changing source.

@Model
final class TranscriptSegment {
    @Attribute(.unique) var id: UUID
    /// The `MeetingItem.id` this segment belongs to.
    var meetingId: UUID
    /// Wall-clock time this segment was captured.
    var timestamp: Date
    /// Physical audio source: "mic" (local mic) or "participant" (system audio).
    var source: String
    /// Human-readable speaker label. Current: "Me", "Participant".
    /// Future diarization can update to "Speaker 1", "Speaker 2", etc.
    var speakerLabel: String
    /// Delta (incremental) transcript text for this segment only.
    var text: String
    /// Tie-break ordering for segments at the same timestamp.
    var sequenceIndex: Int

    init(
        meetingId: UUID,
        timestamp: Date,
        source: String,
        speakerLabel: String,
        text: String,
        sequenceIndex: Int = 0
    ) {
        id                 = UUID()
        self.meetingId     = meetingId
        self.timestamp     = timestamp
        self.source        = source
        self.speakerLabel  = speakerLabel
        self.text          = text
        self.sequenceIndex = sequenceIndex
    }
}

@Model
final class MeetingFolderItem {
    @Attribute(.unique) var id: UUID
    var name: String
    /// User-editable notes about this folder (e.g. "Weekly eng sync with the platform team").
    var folderDescription: String
    var createdAt: Date
    var updatedAt: Date
    var isExpanded: Bool
    var sortIndex: Int
    /// Accent colour identifier: "blue" | "green" | "red" | "orange" | "purple" | "gray".
    var color: String
    /// SF Symbol name for the folder icon: "folder" | "video" | "person.3" | "chart.bar" | etc.
    var icon: String

    init(name: String, sortIndex: Int = 0, color: String = "blue", icon: String = "folder") {
        id = UUID()
        self.name = name
        self.folderDescription = ""
        createdAt = Date()
        updatedAt = Date()
        isExpanded = true
        self.sortIndex = sortIndex
        self.color = color
        self.icon = icon
    }
}

// MARK: - FolderSummaryItem
//
// Persisted cross-meeting intelligence for a folder.
// Generated by FolderSummaryService and cached to avoid repeated AI calls.
// One summary item per folder; regenerated on demand.

@Model
final class FolderSummaryItem {
    @Attribute(.unique) var id: UUID
    /// The `MeetingFolderItem.id` this summary belongs to.
    var folderID: UUID
    /// AI-generated overall summary of all meetings in the folder.
    var overallSummary: String
    /// Decisions that recur across multiple meetings.
    var recurringDecisions: [String]
    /// Action items that recur across multiple meetings.
    var recurringActionItems: [String]
    /// Recurring topics extracted from all meeting content.
    var recurringTopics: [String]
    /// Blockers or impediments that recur across meetings.
    var recurringBlockers: [String]
    /// Risks that surface repeatedly across the folder's meetings.
    var recurringRisks: [String]
    /// Number of meetings included in this summary.
    var meetingCount: Int
    var generatedAt: Date

    init(folderID: UUID) {
        id = UUID()
        self.folderID = folderID
        overallSummary = ""
        recurringDecisions = []
        recurringActionItems = []
        recurringTopics = []
        recurringBlockers = []
        recurringRisks = []
        meetingCount = 0
        generatedAt = Date()
    }
}

@Model
final class CommitmentItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var dueDate: Date?
    var statusValue: String
    var createdAt: Date

    init(title: String, dueDate: Date? = nil) {
        id = UUID()
        self.title = title
        self.dueDate = dueDate
        statusValue = "open"
        createdAt = Date()
    }
}

@Model
final class VaultItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var encryptedSecret: Data
    var itemType: String
    var lastAccessed: Date

    init(title: String, encryptedSecret: Data, itemType: String) {
        id = UUID()
        self.title = title
        self.encryptedSecret = encryptedSecret
        self.itemType = itemType
        lastAccessed = Date()
    }
}

@Model
final class AISuggestionItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var detail: String
    var suggestionType: String
    var statusValue: String
    var createdAt: Date
    var hiddenUntil: Date?

    var status: SuggestionStatus {
        get { SuggestionStatus(rawValue: statusValue) ?? .pending }
        set { statusValue = newValue.rawValue }
    }

    init(title: String, detail: String = "", suggestionType: String = "general") {
        id = UUID()
        self.title = title
        self.detail = detail
        self.suggestionType = suggestionType
        statusValue = SuggestionStatus.pending.rawValue
        createdAt = Date()
    }
}

@Model
final class DailyBriefItem {
    @Attribute(.unique) var id: UUID
    var date: Date
    var focus: String
    var criticalTasks: [String]
    var meetings: [String]
    var commitments: [String]
    var overdueWork: [String]
    var suggestedFocusBlock: String
    var generatedAt: Date

    init(
        date: Date,
        focus: String,
        criticalTasks: [String],
        meetings: [String],
        commitments: [String],
        overdueWork: [String],
        suggestedFocusBlock: String
    ) {
        id = UUID()
        self.date = date
        self.focus = focus
        self.criticalTasks = criticalTasks
        self.meetings = meetings
        self.commitments = commitments
        self.overdueWork = overdueWork
        self.suggestedFocusBlock = suggestedFocusBlock
        generatedAt = Date()
    }
}

@Model
final class FocusPatternItem {
    @Attribute(.unique) var id: UUID
    var preferredStartHour: Int
    var preferredEndHour: Int
    var averageCompletionMinutes: Int
    var interruptionsPerDay: Int
    var updatedAt: Date

    init(preferredStartHour: Int = 9, preferredEndHour: Int = 11) {
        id = UUID()
        self.preferredStartHour = preferredStartHour
        self.preferredEndHour = preferredEndHour
        averageCompletionMinutes = 45
        interruptionsPerDay = 0
        updatedAt = Date()
    }
}
