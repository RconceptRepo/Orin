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
    /// Path to the locally-recorded audio file for this meeting, if any.
    var audioFilePath: String?

    @Relationship(deleteRule: .cascade)
    var commitments: [CommitmentItem] = []

    var tasks: [TaskItem] = []

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
        // CRASH-DIAG: log creation so we can verify object address vs @Query proxy addresses
        CrashDiag.trace("MeetingItem.init id=\(id) addr=\(CrashDiag.addr(self)) title='\(title)'")
    }

    deinit {
        // CRASH-DIAG: if this fires BEFORE the @Query update for TodayView or MeetingsView
        // completes, the @Bindable in MeetingDetailView is referencing freed memory.
        CrashDiag.trace("MeetingItem.deinit id=\(id) addr=\(CrashDiag.addr(self))")
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
