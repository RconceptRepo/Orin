import Foundation
import SwiftData

// MARK: - MeetingExportFormat

enum MeetingExportFormat: String, CaseIterable, Identifiable {
    case json
    case markdown
    case text
    case csv

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .json:     "json"
        case .markdown: "md"
        case .text:     "txt"
        case .csv:      "csv"
        }
    }

    var displayName: String {
        switch self {
        case .json:     "JSON"
        case .markdown: "Markdown"
        case .text:     "Plain Text"
        case .csv:      "CSV"
        }
    }
}

// MARK: - Snapshot Models (unchanged)

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
    /// JSON-encoded [ActionItemRecord] — canonical structured action items.
    /// Nil for legacy exports produced before Phase 2 analysis.
    var structuredActionItemsJSON: String?
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
        structuredActionItemsJSON = meeting.structuredActionItemsJSON
        audioFilePath = meeting.audioFilePath
        tags = meeting.tags
        folderID = meeting.folderID
    }
}

struct MeetingFolderSnapshot: Codable, Identifiable {
    var id: UUID
    var name: String
    var folderDescription: String
    var createdAt: Date
    var updatedAt: Date
    var isExpanded: Bool
    var sortIndex: Int
    var color: String
    var icon: String

    init(_ folder: MeetingFolderItem) {
        id                  = folder.id
        name                = folder.name
        folderDescription   = folder.folderDescription
        createdAt           = folder.createdAt
        updatedAt           = folder.updatedAt
        isExpanded          = folder.isExpanded
        sortIndex           = folder.sortIndex
        color               = folder.color
        icon                = folder.icon
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

// MARK: - Errors

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

// MARK: - MeetingDataService

final class MeetingDataService: Service {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Single-meeting export

    func data(for meeting: MeetingItem, format: MeetingExportFormat) throws -> Data {
        switch format {
        case .json:
            return try encoder.encode(MeetingSnapshot(meeting))
        case .markdown:
            return markdown(for: meeting).data(using: .utf8) ?? Data()
        case .text:
            return plainText(for: meeting).data(using: .utf8) ?? Data()
        case .csv:
            return csv(for: meeting).data(using: .utf8) ?? Data()
        }
    }

    // MARK: - Full-app JSON export

    func exportFullApp(context: ModelContext) throws -> Data {
        let meetings  = try context.fetch(FetchDescriptor<MeetingItem>()).map(MeetingSnapshot.init)
        let folders   = try context.fetch(FetchDescriptor<MeetingFolderItem>()).map(MeetingFolderSnapshot.init)
        let tasks     = try context.fetch(FetchDescriptor<TaskItem>()).map(TaskSnapshot.init)
        let vaultItems = try context.fetch(FetchDescriptor<VaultItem>()).map(VaultMetadataSnapshot.init)
        let package   = OrinExportPackage(
            meetings: meetings,
            folders: folders,
            tasks: tasks,
            vaultMetadata: vaultItems,
            settings: SettingsSnapshot()
        )
        return try encoder.encode(package)
    }

    // MARK: - ZIP bulk export
    //
    // Produces a ZIP archive where each meeting is a separate Markdown file.
    // The ZIP is generated using a pure-Swift implementation (no system utilities
    // or external dependencies) so the method works inside the app sandbox.
    //
    // Format: Orin-Export-<date>/
    //   ├── index.json          (all meetings as JSON array, no vault data)
    //   └── <meeting-title>.md  (one file per meeting)

    func exportMeetingsZip(meetings: [MeetingItem]) throws -> Data {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        let dateStamp = dateFormatter.string(from: Date())
        let folderName = "Orin-Export-\(dateStamp)"

        var writer = ZipWriter()

        // index.json with all meeting metadata
        let snapshots  = meetings.map(MeetingSnapshot.init)
        let indexData  = (try? encoder.encode(snapshots)) ?? Data()
        writer.addFile(name: "\(folderName)/index.json", content: indexData)

        // One markdown file per meeting
        for meeting in meetings {
            let safeTitle = meeting.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let shortDate = dateFormatter.string(from: meeting.date)
            let fileName  = "\(folderName)/\(shortDate) \(safeTitle).md"
            let mdData    = markdown(for: meeting).data(using: .utf8) ?? Data()
            writer.addFile(name: fileName, content: mdData)
        }

        return writer.finalize()
    }

    // MARK: - Import

    @MainActor
    func importPackage(from data: Data, context: ModelContext) throws {
        let package = try decoder.decode(OrinExportPackage.self, from: data)
        guard package.version >= 1 else { throw MeetingDataError.invalidPackage }

        let existingMeetings   = try context.fetch(FetchDescriptor<MeetingItem>())
        let existingMeetingIDs = Set(existingMeetings.map(\.id))
        let existingFolders    = try context.fetch(FetchDescriptor<MeetingFolderItem>())
        let existingFolderIDs  = Set(existingFolders.map(\.id))

        for folder in package.folders where !existingFolderIDs.contains(folder.id) {
            let item = MeetingFolderItem(name: folder.name, sortIndex: folder.sortIndex,
                                         color: folder.color, icon: folder.icon)
            item.id                = folder.id
            item.folderDescription = folder.folderDescription
            item.createdAt         = folder.createdAt
            item.updatedAt         = folder.updatedAt
            item.isExpanded        = folder.isExpanded
            context.insert(item)
        }

        for snapshot in package.meetings where !existingMeetingIDs.contains(snapshot.id) {
            let meeting = MeetingItem(title: snapshot.title, date: snapshot.date, durationSeconds: snapshot.durationSeconds)
            meeting.id                          = snapshot.id
            meeting.participants                = snapshot.participants
            meeting.transcript                  = snapshot.transcript
            meeting.summary                     = snapshot.summary
            meeting.decisions                   = snapshot.decisions
            meeting.actionItems                 = snapshot.actionItems
            meeting.suggestedTaskTitles         = snapshot.suggestedTaskTitles
            meeting.acceptedSuggestedTaskTitles = snapshot.acceptedSuggestedTaskTitles
            meeting.structuredActionItemsJSON   = snapshot.structuredActionItemsJSON
            meeting.audioFilePath               = snapshot.audioFilePath
            meeting.tags                        = snapshot.tags
            meeting.folderID                    = snapshot.folderID
            context.insert(meeting)
        }

        try context.save()
    }

    // MARK: - Format renderers (private)

    private func markdown(for meeting: MeetingItem) -> String {
        let duration = formatDuration(meeting.durationSeconds)
        return """
        # \(meeting.title)

        **Date:** \(meeting.date.formatted(date: .abbreviated, time: .shortened))
        **Duration:** \(duration)
        **Participants:** \(meeting.participants.isEmpty ? "None" : meeting.participants.joined(separator: ", "))

        ## Summary
        \(meeting.summary.isEmpty ? "No summary." : meeting.summary)

        ## Decisions
        \(bulletList(meeting.decisions))

        ## Action Items
        \(structuredActionItemsBulletList(meeting))

        ## Suggested Tasks
        \(bulletList(meeting.suggestedTaskTitles))

        ## Transcript
        \(meeting.transcript.isEmpty ? "No transcript." : meeting.transcript)
        """
    }

    /// Produces a markdown bullet list for action items.
    /// Uses structured items (owner, task, priority, due) when available;
    /// falls back to the flat string array for legacy meetings.
    private func structuredActionItemsBulletList(_ meeting: MeetingItem) -> String {
        let structured = meeting.structuredActionItems
        guard !structured.isEmpty else { return bulletList(meeting.actionItems) }
        return structured.map { item in
            var line = "- **[\(item.owner)]** \(item.task)"
            var meta: [String] = []
            if !item.dueDateText.isEmpty { meta.append("Due: \(item.dueDateText)") }
            if item.priority.lowercased() != "medium" { meta.append("Priority: \(item.priority)") }
            if !meta.isEmpty { line += " _(\(meta.joined(separator: ", ")))_" }
            return line
        }.joined(separator: "\n")
    }

    private func plainText(for meeting: MeetingItem) -> String {
        let duration = formatDuration(meeting.durationSeconds)
        return """
        \(meeting.title)
        \(meeting.date.formatted(date: .abbreviated, time: .shortened)) — \(duration)
        Participants: \(meeting.participants.joined(separator: ", "))

        SUMMARY
        \(meeting.summary)

        DECISIONS
        \(meeting.decisions.joined(separator: "\n"))

        ACTION ITEMS
        \(meeting.actionItems.joined(separator: "\n"))

        TRANSCRIPT
        \(meeting.transcript)
        """
    }

    /// Produces a single-row CSV for the meeting.
    ///
    /// Columns: ID, Date, Duration (s), Title, Participants, Summary, Decisions,
    ///          Action Items, Suggested Tasks, Has Transcript, Has Recording, Tags
    ///
    /// Multi-value fields (participants, decisions, etc.) are joined with semicolons
    /// so each row remains a single CSV row.  Fields containing commas, quotes, or
    /// newlines are double-quoted with internal quotes escaped as `""`.
    private func csv(for meeting: MeetingItem) -> String {
        let header = "ID,Date,Duration (s),Title,Participants,Summary,Decisions,Action Items,Suggested Tasks,Has Transcript,Has Recording,Tags"
        let row = [
            meeting.id.uuidString,
            meeting.date.formatted(date: .numeric, time: .shortened),
            String(Int(meeting.durationSeconds)),
            meeting.title,
            meeting.participants.joined(separator: "; "),
            meeting.summary,
            meeting.decisions.joined(separator: "; "),
            meeting.actionItems.joined(separator: "; "),
            meeting.suggestedTaskTitles.joined(separator: "; "),
            meeting.transcript.isEmpty ? "No" : "Yes",
            meeting.audioFilePath != nil ? "Yes" : "No",
            meeting.tags.joined(separator: "; ")
        ].map(csvEscape).joined(separator: ",")
        return "\(header)\n\(row)\n"
    }

    /// Builds a CSV for multiple meetings (header + one row per meeting).
    func csvBulk(for meetings: [MeetingItem]) -> String {
        let header = "ID,Date,Duration (s),Title,Participants,Summary,Decisions,Action Items,Suggested Tasks,Has Transcript,Has Recording,Tags"
        let rows = meetings.map { meeting in
            [
                meeting.id.uuidString,
                meeting.date.formatted(date: .numeric, time: .shortened),
                String(Int(meeting.durationSeconds)),
                meeting.title,
                meeting.participants.joined(separator: "; "),
                meeting.summary,
                meeting.decisions.joined(separator: "; "),
                meeting.actionItems.joined(separator: "; "),
                meeting.suggestedTaskTitles.joined(separator: "; "),
                meeting.transcript.isEmpty ? "No" : "Yes",
                meeting.audioFilePath != nil ? "Yes" : "No",
                meeting.tags.joined(separator: "; ")
            ].map(csvEscape).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    private func bulletList(_ items: [String]) -> String {
        items.isEmpty ? "None" : items.map { "- \($0)" }.joined(separator: "\n")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s == 0 { return "—" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    /// RFC 4180-compliant CSV field escaping.
    private func csvEscape(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        if needsQuoting {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

// MARK: - ZipWriter
//
// Minimal ZIP archive writer (PKZIP format, no compression / store method).
// Uses no external dependencies — suitable for sandboxed macOS apps.
// Produces valid .zip files readable by macOS Archive Utility, 7-Zip, etc.
//
// Limitations: Store method only (no DEFLATE). Text and JSON files are small
// enough that compression savings are minimal; store avoids the zlib dependency.

private struct ZipWriter {
    private var localEntries = Data()
    private var centralDirectory = Data()
    private var fileCount: UInt16 = 0

    mutating func addFile(name: String, content: Data) {
        let nameBytes = Array(name.utf8)
        let offset    = UInt32(localEntries.count)
        let size      = UInt32(content.count)
        let crc       = crc32(content)

        // Local file header (30 bytes + filename)
        localEntries.append(signature: 0x04034b50)  // local file header signature
        localEntries.appendUInt16(20)    // version needed to extract
        localEntries.appendUInt16(0)     // general purpose bit flag
        localEntries.appendUInt16(0)     // compression method: stored
        localEntries.appendUInt16(0)     // last mod file time
        localEntries.appendUInt16(0)     // last mod file date
        localEntries.appendUInt32(crc)   // CRC-32
        localEntries.appendUInt32(size)  // compressed size
        localEntries.appendUInt32(size)  // uncompressed size
        localEntries.appendUInt16(UInt16(nameBytes.count)) // file name length
        localEntries.appendUInt16(0)     // extra field length
        localEntries.append(contentsOf: nameBytes)
        localEntries.append(content)

        // Central directory file header (46 bytes + filename)
        centralDirectory.append(signature: 0x02014b50)  // central directory signature
        centralDirectory.appendUInt16(20)   // version made by
        centralDirectory.appendUInt16(20)   // version needed
        centralDirectory.appendUInt16(0)    // general purpose bit flag
        centralDirectory.appendUInt16(0)    // compression method: stored
        centralDirectory.appendUInt16(0)    // last mod time
        centralDirectory.appendUInt16(0)    // last mod date
        centralDirectory.appendUInt32(crc)  // CRC-32
        centralDirectory.appendUInt32(size) // compressed size
        centralDirectory.appendUInt32(size) // uncompressed size
        centralDirectory.appendUInt16(UInt16(nameBytes.count)) // file name length
        centralDirectory.appendUInt16(0)    // extra field length
        centralDirectory.appendUInt16(0)    // file comment length
        centralDirectory.appendUInt16(0)    // disk number start
        centralDirectory.appendUInt16(0)    // internal file attributes
        centralDirectory.appendUInt32(0)    // external file attributes
        centralDirectory.appendUInt32(offset) // relative offset of local header
        centralDirectory.append(contentsOf: nameBytes)

        fileCount += 1
    }

    func finalize() -> Data {
        var result             = localEntries
        let cdOffset           = UInt32(result.count)
        result.append(centralDirectory)

        // End of central directory record (22 bytes)
        result.append(signature: 0x06054b50) // end of central dir signature
        result.appendUInt16(0)               // disk number
        result.appendUInt16(0)               // start disk
        result.appendUInt16(fileCount)       // entries on this disk
        result.appendUInt16(fileCount)       // total entries
        result.appendUInt32(UInt32(centralDirectory.count)) // central dir size
        result.appendUInt32(cdOffset)        // offset of central dir
        result.appendUInt16(0)              // comment length

        return result
    }
}

// MARK: - Data extension helpers for ZipWriter

private extension Data {
    mutating func append(signature: UInt32) { appendUInt32(signature) }

    mutating func appendUInt16(_ value: UInt16) {
        let v = value.littleEndian
        Swift.withUnsafeBytes(of: v) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        let v = value.littleEndian
        Swift.withUnsafeBytes(of: v) { append(contentsOf: $0) }
    }
}

// MARK: - CRC-32 (standard polynomial 0xEDB88320)

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
    }
    return ~crc
}
