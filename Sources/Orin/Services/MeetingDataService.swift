import Foundation
import SwiftData

enum MeetingExportFormat: String, CaseIterable, Identifiable {
    case json
    case markdown
    case text

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .json: "json"
        case .markdown: "md"
        case .text: "txt"
        }
    }
}

struct OrinExportPackage: Codable {
    var version = 1
    var exportedAt = Date()
    var meetings: [MeetingSnapshot]
    var folders: [MeetingFolderSnapshot]
    var tasks: [TaskSnapshot]
    var vaultMetadata: [VaultMetadataSnapshot]
    var settings: SettingsSnapshot
}

struct MeetingSnapshot: Codable, Identifiable {
    var id: UUID
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
    var audioFilePath: String?
    var tags: [String]
    var folderID: UUID?

    init(_ meeting: MeetingItem) {
        id = meeting.id
        title = meeting.title
        date = meeting.date
        durationSeconds = meeting.durationSeconds
        participants = meeting.participants
        transcript = meeting.transcript
        summary = meeting.summary
        decisions = meeting.decisions
        actionItems = meeting.actionItems
        suggestedTaskTitles = meeting.suggestedTaskTitles
        acceptedSuggestedTaskTitles = meeting.acceptedSuggestedTaskTitles
        audioFilePath = meeting.audioFilePath
        tags = meeting.tags
        folderID = meeting.folderID
    }
}

struct MeetingFolderSnapshot: Codable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var isExpanded: Bool
    var sortIndex: Int

    init(_ folder: MeetingFolderItem) {
        id = folder.id
        name = folder.name
        createdAt = folder.createdAt
        updatedAt = folder.updatedAt
        isExpanded = folder.isExpanded
        sortIndex = folder.sortIndex
    }
}

struct TaskSnapshot: Codable, Identifiable {
    var id: UUID
    var title: String
    var taskDescription: String
    var priorityValue: Int
    var effortEstimateMinutes: Int
    var dueDate: Date?
    var tags: [String]
    var statusValue: String
    var isBacklog: Bool
    var triggerDate: Date?
    var createdAt: Date

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        taskDescription = task.taskDescription
        priorityValue = task.priorityValue
        effortEstimateMinutes = task.effortEstimateMinutes
        dueDate = task.dueDate
        tags = task.tags
        statusValue = task.statusValue
        isBacklog = task.isBacklog
        triggerDate = task.triggerDate
        createdAt = task.createdAt
    }
}

struct VaultMetadataSnapshot: Codable, Identifiable {
    var id: UUID
    var title: String
    var itemType: String
    var lastAccessed: Date

    init(_ item: VaultItem) {
        id = item.id
        title = item.title
        itemType = item.itemType
        lastAccessed = item.lastAccessed
    }
}

struct SettingsSnapshot: Codable {
    var themeMode: String
    var calendarBackgroundSync: Bool
    var sidebarCollapsed: Bool
    var meetingRetentionDays: Int

    init(defaults: UserDefaults = .standard) {
        themeMode = defaults.string(forKey: "orin.theme.mode") ?? OrinThemeMode.system.rawValue
        calendarBackgroundSync = defaults.object(forKey: "orin.calendar.backgroundSync") as? Bool ?? true
        sidebarCollapsed = defaults.object(forKey: "orin.sidebar.collapsed") as? Bool ?? true
        meetingRetentionDays = defaults.integer(forKey: "orin.meetings.retentionDays")
    }
}

enum MeetingDataError: LocalizedError {
    case invalidPackage
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidPackage: "The selected file is not a valid Orin export."
        case .writeFailed: "Orin could not write the export file."
        }
    }
}

final class MeetingDataService: Service {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func data(for meeting: MeetingItem, format: MeetingExportFormat) throws -> Data {
        switch format {
        case .json:
            return try encoder.encode(MeetingSnapshot(meeting))
        case .markdown:
            return markdown(for: meeting).data(using: .utf8) ?? Data()
        case .text:
            return plainText(for: meeting).data(using: .utf8) ?? Data()
        }
    }

    func exportFullApp(context: ModelContext) throws -> Data {
        let meetings = try context.fetch(FetchDescriptor<MeetingItem>()).map(MeetingSnapshot.init)
        let folders = try context.fetch(FetchDescriptor<MeetingFolderItem>()).map(MeetingFolderSnapshot.init)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>()).map(TaskSnapshot.init)
        let vaultItems = try context.fetch(FetchDescriptor<VaultItem>()).map(VaultMetadataSnapshot.init)
        let package = OrinExportPackage(
            meetings: meetings,
            folders: folders,
            tasks: tasks,
            vaultMetadata: vaultItems,
            settings: SettingsSnapshot()
        )
        return try encoder.encode(package)
    }

    @MainActor
    func importPackage(from data: Data, context: ModelContext) throws {
        let package = try decoder.decode(OrinExportPackage.self, from: data)
        guard package.version >= 1 else { throw MeetingDataError.invalidPackage }

        let existingMeetings = try context.fetch(FetchDescriptor<MeetingItem>())
        let existingMeetingIDs = Set(existingMeetings.map(\.id))
        let existingFolders = try context.fetch(FetchDescriptor<MeetingFolderItem>())
        let existingFolderIDs = Set(existingFolders.map(\.id))

        for folder in package.folders where !existingFolderIDs.contains(folder.id) {
            let item = MeetingFolderItem(name: folder.name, sortIndex: folder.sortIndex)
            item.id = folder.id
            item.createdAt = folder.createdAt
            item.updatedAt = folder.updatedAt
            item.isExpanded = folder.isExpanded
            context.insert(item)
        }

        for snapshot in package.meetings where !existingMeetingIDs.contains(snapshot.id) {
            let meeting = MeetingItem(title: snapshot.title, date: snapshot.date, durationSeconds: snapshot.durationSeconds)
            meeting.id = snapshot.id
            meeting.participants = snapshot.participants
            meeting.transcript = snapshot.transcript
            meeting.summary = snapshot.summary
            meeting.decisions = snapshot.decisions
            meeting.actionItems = snapshot.actionItems
            meeting.suggestedTaskTitles = snapshot.suggestedTaskTitles
            meeting.acceptedSuggestedTaskTitles = snapshot.acceptedSuggestedTaskTitles
            meeting.audioFilePath = snapshot.audioFilePath
            meeting.tags = snapshot.tags
            meeting.folderID = snapshot.folderID
            context.insert(meeting)
        }

        try context.save()
    }

    private func markdown(for meeting: MeetingItem) -> String {
        """
        # \(meeting.title)

        Date: \(meeting.date.formatted(date: .abbreviated, time: .shortened))
        Duration: \(Int(meeting.durationSeconds)) seconds
        Participants: \(meeting.participants.isEmpty ? "None" : meeting.participants.joined(separator: ", "))

        ## Summary
        \(meeting.summary.isEmpty ? "No summary." : meeting.summary)

        ## Decisions
        \(bulletList(meeting.decisions))

        ## Action Items
        \(bulletList(meeting.actionItems))

        ## Transcript
        \(meeting.transcript.isEmpty ? "No transcript." : meeting.transcript)
        """
    }

    private func plainText(for meeting: MeetingItem) -> String {
        """
        \(meeting.title)
        \(meeting.date.formatted(date: .abbreviated, time: .shortened))

        Summary:
        \(meeting.summary)

        Decisions:
        \(meeting.decisions.joined(separator: "\n"))

        Action Items:
        \(meeting.actionItems.joined(separator: "\n"))

        Transcript:
        \(meeting.transcript)
        """
    }

    private func bulletList(_ items: [String]) -> String {
        items.isEmpty ? "None" : items.map { "- \($0)" }.joined(separator: "\n")
    }
}
