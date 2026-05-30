import AppKit
import EventKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MeetingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \MeetingItem.date, order: .forward)
    private var allMeetings: [MeetingItem]
    @Query(sort: \MeetingFolderItem.sortIndex, order: .forward)
    private var folders: [MeetingFolderItem]
    @Query(sort: \TranscriptSegment.timestamp, order: .forward)
    private var allSegments: [TranscriptSegment]
    @Query private var allFolderSummaries: [FolderSummaryItem]

    @State private var selectedMeetingID: UUID?
    @State private var selectedFolderID: UUID?       // when set → FolderDetailView shown
    @State private var isCreatingMeeting = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var importStatus: String?
    // Legacy single-suggestion removed — replaced by recurringPatterns list
    @State private var recurringPatterns: [RecurringPattern] = []

    @State private var selectedMeetingIDs: Set<UUID> = []
    @State private var isPastExpanded = false
    @State private var isUpcomingExpanded = true
    @State private var renamingFolder: MeetingFolderItem?   // triggers rename sheet
    @State private var renameText = ""

    @State private var recordingService = ServiceContainer.shared.resolve(RecordingService.self)
    @State private var meetingDetector = ServiceContainer.shared.resolve(MeetingDetectorService.self)
    @State private var systemAudioService = ServiceContainer.shared.resolve(SystemAudioCaptureService.self)
    @State private var transcriptStore = ServiceContainer.shared.resolve(TranscriptStore.self)
    @State private var calendarService = ServiceContainer.shared.resolve(CalendarService.self)

    private let dataService            = ServiceContainer.shared.resolve(MeetingDataService.self)
    private let recurringService       = ServiceContainer.shared.resolve(RecurringMeetingService.self)
    private let folderSummaryService   = ServiceContainer.shared.resolve(FolderSummaryService.self)
    private let aiService              = ServiceContainer.shared.resolve(AIService.self)

    // Convenience: folder selected for detail view
    private var selectedFolder: MeetingFolderItem? {
        guard let id = selectedFolderID else { return nil }
        return folders.first { $0.id == id }
    }

    // Convenience: summary for selected folder (most recent generation)
    private var selectedFolderSummary: FolderSummaryItem? {
        guard let id = selectedFolderID else { return nil }
        return allFolderSummaries.filter { $0.folderID == id }.max(by: { $0.generatedAt < $1.generatedAt })
    }

    private var meetings: [MeetingItem] {
        allMeetings.filter { $0.deletedAt == nil }
    }

    private var selectedMeeting: MeetingItem? {
        meetings.first { $0.id == selectedMeetingID }
    }

    private var unfiledMeetings: [MeetingItem] {
        meetings.filter { $0.folderID == nil }.sorted(by: meetingSort)
    }

    var body: some View {
        HSplitView {
            meetingList
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 520, maxHeight: .infinity)

            if let folder = selectedFolder {
                FolderDetailView(
                    folder: folder,
                    meetings: meetings.filter { $0.folderID == folder.id }
                                      .sorted { $0.date > $1.date },
                    folderSummary: selectedFolderSummary,
                    onGenerateSummary: { await generateFolderSummary(for: folder) },
                    onSelectMeeting: { m in
                        selectedFolderID = nil
                        selectedMeetingID = m.id
                    }
                )
                .frame(minWidth: 620, maxHeight: .infinity)
            } else if let selectedMeeting {
                MeetingDetailView(
                    meeting: selectedMeeting,
                    folders: folders,
                    segments: allSegments.filter { $0.meetingId == selectedMeeting.id },
                    onExport: { export(meeting: selectedMeeting, format: $0) },
                    onMoveToFolder: { folder in move(selectedMeeting, to: folder) }
                )
                .frame(minWidth: 620, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Meeting Selected",
                    systemImage: "video",
                    description: Text("Select a meeting or folder to see details.")
                )
                .frame(minWidth: 620, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isCreatingMeeting) {
            MeetingEditorView { draft in
                let meeting = MeetingItem(title: draft.title, date: draft.date)
                meeting.participants = draft.participantsList
                modelContext.insert(meeting)
                modelContext.safeSave(context: "meeting")
                selectedMeetingID = meeting.id
            }
        }
        .sheet(isPresented: $isCreatingFolder) {
            folderSheet
        }
        .onAppear {
            refreshRecurringPatterns()
        }
        .onChange(of: allMeetings.count) { _, _ in
            refreshRecurringPatterns()
        }
        // Rename folder sheet
        .sheet(item: $renamingFolder) { folder in
            RenameFolderSheet(
                currentName: folder.name,
                onSave: { newName in
                    folder.name = newName
                    folder.updatedAt = Date()
                    modelContext.safeSave(context: "folder rename")
                    renamingFolder = nil
                },
                onCancel: { renamingFolder = nil }
            )
        }
    }

    // MARK: - Meeting List Panel

    private var meetingList: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Text("Meetings")
                    .font(OrinFont.pageTitle)
                    .foregroundStyle(OrinColor.primaryText(colorScheme))
                Spacer()
                Button {
                    isCreatingMeeting = true
                } label: {
                    Label("New Meeting", systemImage: "plus")
                }
                .buttonStyle(OrinSecondaryButtonStyle())

                Menu {
                    Button("Create Folder") { isCreatingFolder = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .medium))
                }
                .menuStyle(.button)
                .help("Meeting actions")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if let importStatus {
                Text(importStatus)
                    .font(OrinFont.caption)
                    .foregroundStyle(OrinColor.secondaryText(colorScheme))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            if meetings.isEmpty && folders.isEmpty {
                EmptyMeetingsState(onCreateMeeting: { isCreatingMeeting = true })
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Recurring meeting suggestion banners — up to 3 at once
                        ForEach(recurringPatterns.prefix(3)) { pattern in
                            RecurringSuggestionBanner(
                                pattern: pattern,
                                onAccept: { acceptPattern(pattern) },
                                onDismiss: { dismissPattern(pattern) }
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                        }
                        comingUpSection
                        folderBlocksSection
                        pastSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, selectedMeetingIDs.isEmpty ? 20 : 72)
                }
            }

            if !selectedMeetingIDs.isEmpty {
                multiSelectBar
            }
        }
        .background(OrinColor.backgroundPrimary(colorScheme))
    }

    // MARK: - Coming Up Section

    private var comingUpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isUpcomingExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isUpcomingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                    Text("Coming Up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isUpcomingExpanded {
                let upcomingMeetings = upcomingUnfiled
                let calendarEvents   = calendarOnlyUpcomingEvents
                if upcomingMeetings.isEmpty && calendarEvents.isEmpty {
                    Text("No upcoming meetings.")
                        .font(.system(size: 13))
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                } else {
                    // Orin MeetingItem rows grouped by day
                    let groups = groupByDay(upcomingMeetings)
                    ForEach(groups, id: \.date) { group in
                        UpcomingDayGroupCard(
                            dayDate: group.date,
                            dayMeetings: group.meetings,
                            selectedMeetingID: selectedMeetingID,
                            onSelect: { selectedMeetingID = $0.id },
                            onRecord: { startManualRecording(for: $0) }
                        )
                        .padding(.bottom, 4)
                    }
                    // Calendar-only events (no Orin MeetingItem yet)
                    if !calendarEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("From Calendar")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(OrinColor.secondaryText(colorScheme))
                                .padding(.horizontal, 8)
                                .padding(.top, 4)
                            ForEach(calendarEvents, id: \.eventIdentifier) { event in
                                CalendarOnlyEventRow(
                                    event: event,
                                    onCreate: {
                                        let m = MeetingItem(
                                            title: event.title ?? "Meeting",
                                            date: event.startDate,
                                            durationSeconds: event.endDate.timeIntervalSince(event.startDate)
                                        )
                                        m.externalEventIdentifier = event.eventIdentifier
                                        modelContext.insert(m)
                                        modelContext.safeSave(context: "meeting from calendar")
                                        selectedMeetingID = m.id
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Folder Blocks

    private var folderBlocksSection: some View {
        ForEach(folders) { folder in
            GranolaFolderBlockView(
                folder: folder,
                meetings: meetings.filter { $0.folderID == folder.id }.sorted(by: meetingSort),
                selectedMeetingID: selectedMeetingID,
                selectedMeetingIDs: $selectedMeetingIDs,
                folders: folders,
                onToggle: {
                    folder.isExpanded.toggle()
                    folder.updatedAt = Date()
                    modelContext.safeSave(context: "meeting folder")
                },
                onSelectFolder: {
                    selectedMeetingID = nil
                    selectedFolderID  = folder.id
                },
                onSelect: {
                    selectedFolderID  = nil
                    selectedMeetingID = $0.id
                },
                onRecord: { startManualRecording(for: $0) },
                onExport: { export(meeting: $0, format: $1) },
                onMoveToFolder: { move($0, to: $1) },
                onCreateFolder: { isCreatingFolder = true },
                onDeleteFolder: { deleteFolder(folder) },
                onRenameFolder: {
                    renameText    = folder.name
                    renamingFolder = folder
                },
                onDeleteMeeting: { deleteMeeting($0) }
            )
        }
    }

    // MARK: - Past Section

    private var pastSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPastExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isPastExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                    Text("Past")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isPastExpanded {
                let pastMeetings = pastUnfiled  // already sorted newest-first
                if pastMeetings.isEmpty {
                    Text("No past meetings.")
                        .font(.system(size: 13))
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                } else {
                    // pastUnfiled is sorted descending; groupByDay then sorts group keys
                    // ascending — override to show most-recent groups first.
                    let groups = groupByDay(pastMeetings, descending: true)
                    ForEach(groups, id: \.date) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dayHeaderString(group.date))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(OrinColor.secondaryText(colorScheme))
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                                .padding(.bottom, 2)

                            ForEach(group.meetings, id: \.id) { meeting in
                                PastMeetingRowView(
                                    meeting: meeting,
                                    isSelected: selectedMeetingID == meeting.id,
                                    selectedIDs: $selectedMeetingIDs,
                                    folders: folders,
                                    onSelect: { selectedMeetingID = meeting.id },
                                    onRecord: { startManualRecording(for: meeting) },
                                    onExport: { export(meeting: meeting, format: $0) },
                                    onMoveToFolder: { move(meeting, to: $0) },
                                    onCreateFolder: { isCreatingFolder = true },
                                    onDelete: { deleteMeeting(meeting) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Multi-select Bar

    private var multiSelectBar: some View {
        HStack(spacing: 12) {
            Button {
                selectedMeetingIDs.removeAll()
            } label: {
                HStack(spacing: 6) {
                    Text("\(selectedMeetingIDs.count) selected")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16)

            Menu {
                ForEach(folders) { folder in
                    Button(folder.name) { moveSelectedToFolder(folder) }
                }
            } label: {
                Label("Add to folder", systemImage: "folder.badge.plus")
                    .font(.system(size: 13))
            }
            .menuStyle(.button)

            Spacer()

            Button(role: .destructive) {
                deleteSelectedMeetings()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(OrinColor.border(colorScheme)).frame(height: 1)
        }
    }

    // MARK: - Folder Sheet

    private var folderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Folder")
                .font(.title2.weight(.semibold))
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isCreatingFolder = false }
                Button("Create") {
                    createFolder()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }

    // MARK: - Computed Helpers

    /// Meetings that have NOT fully ended yet (endDate > now).
    /// Includes in-progress meetings so they stay in "Coming Up" until they finish.
    private var upcomingUnfiled: [MeetingItem] {
        let now = Date()
        return unfiledMeetings
            .filter { $0.endDate > now }
            .sorted { $0.date < $1.date }
    }

    /// Meetings that have fully ended (endDate ≤ now).
    /// Sorted most-recent-first so the latest past meeting is at the top.
    private var pastUnfiled: [MeetingItem] {
        let now = Date()
        return unfiledMeetings
            .filter { $0.endDate <= now }
            .sorted { $0.date > $1.date }
    }

    /// EKEvent entries from CalendarService that start in the future and have no
    /// corresponding MeetingItem (matched via externalEventIdentifier).
    /// Shown in the "Coming Up" section alongside MeetingItems.
    private var calendarOnlyUpcomingEvents: [EKEvent] {
        let now = Date()
        let knownIdentifiers = Set(allMeetings.compactMap { $0.externalEventIdentifier })
        return calendarService.events
            .filter { event in
                event.startDate > now &&
                !knownIdentifiers.contains(event.eventIdentifier ?? "")
            }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Day grouping

    private struct DayGroup {
        let date: Date
        let meetings: [MeetingItem]
    }

    private func groupByDay(_ items: [MeetingItem], descending: Bool = false) -> [DayGroup] {
        let cal = Calendar.current
        var result: [Date: [MeetingItem]] = [:]
        for item in items {
            let day = cal.startOfDay(for: item.date)
            result[day, default: []].append(item)
        }
        let sortedKeys = result.keys.sorted(by: descending ? (>) : (<))
        return sortedKeys.map { day in
            DayGroup(
                date: day,
                meetings: result[day]!.sorted(by: descending
                    ? { $0.date > $1.date }
                    : { $0.date < $1.date })
            )
        }
    }

    private func dayHeaderString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    // MARK: - Business Logic

    private func meetingSort(_ lhs: MeetingItem, _ rhs: MeetingItem) -> Bool {
        let now = Date()
        let lUpcoming = lhs.date >= now
        let rUpcoming = rhs.date >= now
        if lUpcoming != rUpcoming { return lUpcoming }
        return lUpcoming ? lhs.date < rhs.date : lhs.date > rhs.date
    }

    private func startManualRecording(for meeting: MeetingItem) {
        selectedMeetingID = meeting.id
        Task {
            await recordingService.startRecording(for: meeting.id)
            guard recordingService.isRecording else { return }
            // Begin TranscriptStore session AFTER recording is confirmed running.
            transcriptStore.beginSession(meetingID: meeting.id, meeting: meeting, context: modelContext)
            await systemAudioService.startCapturing(for: meeting.id)
        }
    }

    private func move(_ meeting: MeetingItem, to folder: MeetingFolderItem?) {
        meeting.folderID = folder?.id
        modelContext.safeSave(context: "meeting folder move")
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        modelContext.insert(MeetingFolderItem(name: trimmed, sortIndex: folders.count))
        modelContext.safeSave(context: "meeting folder")
        newFolderName = ""
        isCreatingFolder = false
    }

    private func deleteFolder(_ folder: MeetingFolderItem) {
        for meeting in meetings where meeting.folderID == folder.id {
            meeting.folderID = nil
        }
        modelContext.delete(folder)
        modelContext.safeSave(context: "meeting folder delete")
    }

    private func deleteMeeting(_ meeting: MeetingItem) {
        if selectedMeetingID == meeting.id { selectedMeetingID = nil }
        if selectedFolderID == meeting.folderID    { /* keep folder open */ }
        modelContext.deleteMeetingFully(meeting)
        modelContext.safeSave(context: "meeting delete")
    }

    // MARK: - Recurring Pattern Management

    private func refreshRecurringPatterns() {
        let folderNames = folders.map(\.name)
        recurringPatterns = recurringService.detectPatterns(
            in: meetings,
            existingFolderNames: folderNames
        )
    }

    private func acceptPattern(_ pattern: RecurringPattern) {
        let folder = MeetingFolderItem(name: pattern.suggestedFolderName, sortIndex: folders.count)
        modelContext.insert(folder)
        for meeting in meetings where pattern.meetingIDs.contains(meeting.id) {
            meeting.folderID = folder.id
        }
        modelContext.safeSave(context: "recurring meeting folder")
        // Remove the accepted pattern from the list
        recurringPatterns.removeAll { $0.id == pattern.id }
        refreshRecurringPatterns()
    }

    private func dismissPattern(_ pattern: RecurringPattern) {
        UserDefaults.standard.set(true, forKey: pattern.dismissedKey)
        recurringPatterns.removeAll { $0.id == pattern.id }
    }

    // MARK: - Folder Summary Generation

    @MainActor
    private func generateFolderSummary(for folder: MeetingFolderItem) async {
        let folderMeetings = meetings.filter { $0.folderID == folder.id }
        let summary = await folderSummaryService.generate(
            folderName: folder.name,
            folderID:   folder.id,
            meetings:   folderMeetings,
            aiService:  aiService
        )
        modelContext.insert(summary)
        modelContext.safeSave(context: "folder summary")
    }

    private func export(meeting: MeetingItem, format: MeetingExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try dataService.data(for: meeting, format: format)
                try data.write(to: url, options: .atomic)
                importStatus = "Exported \(url.lastPathComponent)."
            } catch {
                importStatus = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func removeRecordingFile(for meeting: MeetingItem) {
        guard let path = meeting.audioFilePath else { return }
        try? FileManager.default.removeItem(atPath: path)
        meeting.audioFilePath = nil
        meeting.recordingDeletedAt = Date()
    }

    private func moveSelectedToFolder(_ folder: MeetingFolderItem) {
        for id in selectedMeetingIDs {
            if let m = meetings.first(where: { $0.id == id }) { m.folderID = folder.id }
        }
        modelContext.safeSave(context: "multi move to folder")
        selectedMeetingIDs.removeAll()
    }

    private func deleteSelectedMeetings() {
        for id in selectedMeetingIDs {
            if let m = meetings.first(where: { $0.id == id }) { deleteMeeting(m) }
        }
        selectedMeetingIDs.removeAll()
    }
}

// MARK: - Upcoming Day Group Card

private struct UpcomingDayGroupCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let dayDate: Date
    let dayMeetings: [MeetingItem]
    let selectedMeetingID: UUID?
    var onSelect: (MeetingItem) -> Void
    var onRecord: (MeetingItem) -> Void

    private var dayNumber: String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: dayDate)
    }

    private var monthAbbrev: String {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f.string(from: dayDate)
    }

    private var dayAbbrev: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: dayDate)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left date column
            VStack(spacing: 1) {
                Text(dayNumber)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(OrinColor.primaryText(colorScheme))
                Text(monthAbbrev)
                    .font(.system(size: 11))
                    .foregroundStyle(OrinColor.secondaryText(colorScheme))
                Text(dayAbbrev)
                    .font(.system(size: 11))
                    .foregroundStyle(OrinColor.secondaryText(colorScheme))
            }
            .frame(width: 52)

            // Vertical separator
            Rectangle()
                .fill(OrinColor.border(colorScheme))
                .frame(width: 1)
                .padding(.vertical, 2)

            // Meetings list
            VStack(alignment: .leading, spacing: 10) {
                ForEach(dayMeetings, id: \.id) { meeting in
                    UpcomingMeetingItemRow(
                        meeting: meeting,
                        isSelected: selectedMeetingID == meeting.id,
                        onSelect: { onSelect(meeting) },
                        onRecord: { onRecord(meeting) }
                    )
                }
            }
            .padding(.leading, 12)
        }
        .padding(14)
        .background(OrinColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(OrinColor.border(colorScheme), lineWidth: 1)
        }
    }
}

// MARK: - Upcoming Meeting Item Row

private struct UpcomingMeetingItemRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    let meeting: MeetingItem
    let isSelected: Bool
    var onSelect: () -> Void
    var onRecord: () -> Void

    private var isMeetingNow: Bool {
        let now = Date()
        let duration = max(meeting.durationSeconds, 3600)
        return now >= meeting.date && now <= meeting.date.addingTimeInterval(duration)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if isMeetingNow {
            if meeting.durationSeconds > 0 {
                let end = meeting.date.addingTimeInterval(meeting.durationSeconds)
                return "Now · \(formatter.string(from: meeting.date))–\(formatter.string(from: end))"
            }
            return "Now · \(formatter.string(from: meeting.date))"
        }
        if meeting.durationSeconds > 0 {
            let end = meeting.date.addingTimeInterval(meeting.durationSeconds)
            return "\(formatter.string(from: meeting.date))–\(formatter.string(from: end))"
        }
        return formatter.string(from: meeting.date)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Left color border
                RoundedRectangle(cornerRadius: 2)
                    .fill(isMeetingNow ? Color.green : OrinColor.accent)
                    .frame(width: 3, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? OrinColor.accent : OrinColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text(timeString)
                        .font(.system(size: 11))
                        .foregroundStyle(isMeetingNow ? Color.green : OrinColor.secondaryText(colorScheme))
                }

                Spacer()

                // Quick record button
                Button(action: onRecord) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(OrinColor.error)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0.4)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Granola Folder Block View

private struct GranolaFolderBlockView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var folder: MeetingFolderItem
    let meetings: [MeetingItem]
    let selectedMeetingID: UUID?
    @Binding var selectedMeetingIDs: Set<UUID>
    let folders: [MeetingFolderItem]
    var onToggle: () -> Void
    var onSelectFolder: () -> Void    // tap folder name → show FolderDetailView
    var onSelect: (MeetingItem) -> Void
    var onRecord: (MeetingItem) -> Void
    var onExport: (MeetingItem, MeetingExportFormat) -> Void
    var onMoveToFolder: (MeetingItem, MeetingFolderItem?) -> Void
    var onCreateFolder: () -> Void
    var onDeleteFolder: () -> Void
    var onRenameFolder: () -> Void    // triggers rename sheet
    var onDeleteMeeting: (MeetingItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Folder header row
            HStack {
                // Expand/collapse toggle (chevron only)
                Button(action: onToggle) {
                    Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)

                // Folder name → opens FolderDetailView
                Button(action: onSelectFolder) {
                    HStack(spacing: 8) {
                        Image(systemName: folder.icon)
                            .foregroundStyle(OrinColor.accent)
                        Text(folder.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OrinColor.primaryText(colorScheme))
                        Text("\(meetings.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15))
                            .clipShape(Capsule())
                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                Menu {
                    Button("Rename Folder", action: onRenameFolder)
                    Divider()
                    Button(role: .destructive, action: onDeleteFolder) {
                        Label("Delete Folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())

            if folder.isExpanded {
                ForEach(meetings, id: \.id) { meeting in
                    PastMeetingRowView(
                        meeting: meeting,
                        isSelected: selectedMeetingID == meeting.id,
                        selectedIDs: $selectedMeetingIDs,
                        folders: folders,
                        onSelect: { onSelect(meeting) },
                        onRecord: { onRecord(meeting) },
                        onExport: { onExport(meeting, $0) },
                        onMoveToFolder: { onMoveToFolder(meeting, $0) },
                        onCreateFolder: onCreateFolder,
                        onDelete: { onDeleteMeeting(meeting) }
                    )
                }
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Past Meeting Row View

private struct PastMeetingRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    let meeting: MeetingItem
    let isSelected: Bool
    @Binding var selectedIDs: Set<UUID>
    let folders: [MeetingFolderItem]
    var onSelect: () -> Void
    var onRecord: () -> Void
    var onExport: (MeetingExportFormat) -> Void
    var onMoveToFolder: (MeetingFolderItem?) -> Void
    var onCreateFolder: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Checkbox - visible on hover or when multi-select active
            Button {
                if selectedIDs.contains(meeting.id) {
                    selectedIDs.remove(meeting.id)
                } else {
                    selectedIDs.insert(meeting.id)
                }
            } label: {
                Image(systemName: selectedIDs.contains(meeting.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(meeting.id) ? OrinColor.accent : .secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .opacity(isHovered || !selectedIDs.isEmpty ? 1 : 0)

            // Status icon: recorded vs. unrecorded
            Image(systemName: meeting.audioFilePath != nil ? "waveform" : "doc.text")
                .foregroundStyle(meeting.audioFilePath != nil ? OrinColor.accent.opacity(0.7) : .secondary)
                .font(.system(size: 14))

            // Title + participants + metadata badges
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? OrinColor.accent : OrinColor.primaryText(colorScheme))
                    .lineLimit(1)
                Text(meeting.participants.isEmpty
                     ? "Me"
                     : meeting.participants.prefix(2).joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // Metadata badges: only shown when non-trivial
                MeetingMetaBadgeRow(meeting: meeting)
            }

            Spacer()

            // Time
            Text(meeting.date, format: .dateTime.hour().minute())
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            // 3-dot menu
            Menu {
                Button("Start Recording") { onRecord() }
                Menu("Export") {
                    Button("Markdown") { onExport(.markdown) }
                    Button("Text") { onExport(.text) }
                    Button("JSON") { onExport(.json) }
                    Button("CSV") { onExport(.csv) }
                }
                Menu("Move to Folder") {
                    Button("Remove from Folder") { onMoveToFolder(nil) }
                    Divider()
                    ForEach(folders) { folder in
                        Button(folder.name) { onMoveToFolder(folder) }
                    }
                    Divider()
                    Button("Create Folder") { onCreateFolder() }
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .opacity(isHovered ? 1 : 0.3)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            isSelected
                ? OrinColor.accent.opacity(0.08)
                : (isHovered ? OrinColor.backgroundSecondary(colorScheme) : Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
    }
}

// MARK: - Supporting Types

// MARK: - Meeting Metadata Badge Row
//
// Compact set of status badges shown below the meeting title in PastMeetingRowView.
// Only non-trivial data is shown (zero values are hidden to avoid noise).

private struct MeetingMetaBadgeRow: View {
    let meeting: MeetingItem

    private var durationText: String? {
        guard meeting.durationSeconds > 60 else { return nil }
        let m = Int(meeting.durationSeconds) / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    var body: some View {
        let hasDuration     = durationText != nil
        let hasActions      = !meeting.actionItems.isEmpty
        let hasSummary      = !meeting.summary.isEmpty
        let hasTranscript   = !meeting.transcript.isEmpty

        // Only render the row if there's at least one badge to show
        if hasDuration || hasActions || hasSummary || hasTranscript {
            HStack(spacing: 6) {
                if let dur = durationText {
                    MetaBadge(icon: "clock", label: dur, color: .secondary)
                }
                if hasSummary {
                    MetaBadge(icon: "sparkles", label: "Analyzed", color: .green)
                }
                if hasActions {
                    MetaBadge(icon: "checklist", label: "\(meeting.actionItems.count)", color: .blue)
                }
                if hasTranscript && !hasSummary {
                    MetaBadge(icon: "text.bubble", label: "Transcript", color: .secondary)
                }
            }
        }
    }
}

private struct MetaBadge: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color.opacity(0.85))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
    }
}

// MARK: - Empty Meetings State

private struct EmptyMeetingsState: View {
    @Environment(\.colorScheme) private var colorScheme
    var onCreateMeeting: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "video.slash")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(OrinColor.secondaryText(colorScheme))

            VStack(spacing: 8) {
                Text("No Meetings Yet")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(OrinColor.primaryText(colorScheme))
                Text("Orin will detect and prompt to record your meetings automatically.\nYou can also start a recording manually.")
                    .font(.body)
                    .foregroundStyle(OrinColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 10) {
                Button(action: onCreateMeeting) {
                    Label("New Meeting", systemImage: "plus")
                }
                .buttonStyle(OrinPrimaryButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Recurring Suggestion Banner

/// Inline card shown at the top of the meeting list when a recurring pattern is detected.
/// Shows Accept / Dismiss actions without blocking the UI.
private struct RecurringSuggestionBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    let pattern: RecurringPattern
    var onAccept: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(OrinColor.accent)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 3) {
                Text("Create \"\(pattern.suggestedFolderName)\" folder?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OrinColor.primaryText(colorScheme))
                Text(pattern.summaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(OrinColor.secondaryText(colorScheme))
            }

            Spacer()

            Button("Dismiss") { onDismiss() }
                .buttonStyle(OrinSecondaryButtonStyle())
                .font(.system(size: 11))

            Button("Create") { onAccept() }
                .buttonStyle(OrinPrimaryButtonStyle())
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(OrinColor.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(OrinColor.accent.opacity(0.2), lineWidth: 1)
        }
    }
}

// MARK: - Rename Folder Sheet

private struct RenameFolderSheet: View {
    @State private var name: String
    var onSave: (String) -> Void
    var onCancel: () -> Void

    init(currentName: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _name    = State(initialValue: currentName)
        self.onSave   = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Folder")
                .font(.title2.weight(.semibold))
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSave(trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}

// MARK: - Folder Detail View

private enum FolderDetailTab: String, CaseIterable {
    case meetings    = "Meetings"
    case intelligence = "Intelligence"
}

private struct FolderDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var folder: MeetingFolderItem
    let meetings: [MeetingItem]
    let folderSummary: FolderSummaryItem?
    var onGenerateSummary: () async -> Void
    var onSelectMeeting: (MeetingItem) -> Void

    @State private var activeTab: FolderDetailTab = .meetings
    @State private var isGenerating = false

    private var folderColor: Color {
        switch folder.color {
        case "green":  return .green
        case "red":    return .red
        case "orange": return .orange
        case "purple": return .purple
        case "gray":   return .gray
        default:       return OrinColor.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: folder.icon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(folderColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.name)
                        .font(OrinFont.pageTitle)
                        .foregroundStyle(OrinColor.primaryText(colorScheme))
                    Text("\(meetings.count) meeting\(meetings.count == 1 ? "" : "s")" + (meetings.first.map { " · Last: \($0.date.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                        .font(OrinFont.body)
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                    if !folder.folderDescription.isEmpty {
                        Text(folder.folderDescription)
                            .font(OrinFont.caption)
                            .foregroundStyle(OrinColor.secondaryText(colorScheme))
                    }
                }
                Spacer()
            }

            // Tab picker
            Picker("", selection: $activeTab) {
                ForEach(FolderDetailTab.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            // Tab content
            switch activeTab {
            case .meetings:
                meetingsTab
            case .intelligence:
                intelligenceTab
            }

            Spacer()
        }
        .padding(24)
        .background(OrinColor.backgroundPrimary(colorScheme))
    }

    // MARK: - Meetings Tab

    private var meetingsTab: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if meetings.isEmpty {
                    Text("No meetings in this folder yet.")
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                        .padding(.top, 20)
                } else {
                    ForEach(meetings, id: \.id) { meeting in
                        FolderMeetingRow(meeting: meeting, onSelect: { onSelectMeeting(meeting) })
                    }
                }
            }
        }
    }

    // MARK: - Intelligence Tab

    private var intelligenceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = folderSummary {
                    OrinCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Overall Summary").font(OrinFont.cardTitle)
                                Spacer()
                                Text(summary.generatedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(OrinFont.caption)
                                    .foregroundStyle(OrinColor.secondaryText(colorScheme))
                            }
                            Text(summary.overallSummary.isEmpty ? "No summary available." : summary.overallSummary)
                                .font(OrinFont.body)
                                .foregroundStyle(summary.overallSummary.isEmpty
                                    ? OrinColor.secondaryText(colorScheme)
                                    : OrinColor.primaryText(colorScheme))
                        }
                    }

                    if !summary.recurringTopics.isEmpty {
                        OrinCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Recurring Topics").font(OrinFont.cardTitle)
                                FlowTagView(tags: summary.recurringTopics)
                            }
                        }
                    }

                    if !summary.recurringDecisions.isEmpty {
                        InsightCard(title: "Recurring Decisions", items: summary.recurringDecisions)
                    }

                    if !summary.recurringActionItems.isEmpty {
                        InsightCard(title: "Recurring Action Items", items: summary.recurringActionItems)
                    }
                } else {
                    OrinCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Folder Intelligence").font(OrinFont.cardTitle)
                            Text("Generate a cross-meeting summary, recurring topics, and action item patterns for all meetings in this folder.")
                                .font(OrinFont.body)
                                .foregroundStyle(OrinColor.secondaryText(colorScheme))
                            Button {
                                Task {
                                    isGenerating = true
                                    await onGenerateSummary()
                                    isGenerating = false
                                }
                            } label: {
                                Label(isGenerating ? "Analyzing…" : "Generate Summary", systemImage: "sparkles")
                            }
                            .buttonStyle(OrinPrimaryButtonStyle())
                            .disabled(isGenerating || meetings.isEmpty)
                        }
                    }
                }

                if folderSummary != nil && !meetings.isEmpty {
                    Button {
                        Task {
                            isGenerating = true
                            await onGenerateSummary()
                            isGenerating = false
                        }
                    } label: {
                        Label(isGenerating ? "Analyzing…" : "Regenerate", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(OrinSecondaryButtonStyle())
                    .disabled(isGenerating)
                }
            }
            .padding(.trailing, 8)
        }
    }
}

// MARK: - Folder Meeting Row

private struct FolderMeetingRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let meeting: MeetingItem
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: meeting.transcript.isEmpty ? "doc" : "doc.text.fill")
                    .foregroundStyle(meeting.transcript.isEmpty ? Color.secondary : OrinColor.accent)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OrinColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !meeting.summary.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow Tag View (for recurring topics)

private struct FlowTagView: View {
    let tags: [String]
    var body: some View {
        // Simple wrapping layout using nested HStacks
        VStack(alignment: .leading, spacing: 4) {
            let rows = chunked(tags, size: 3)
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    ForEach(rows[i], id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(OrinColor.accent.opacity(0.12))
                            .foregroundStyle(OrinColor.accent)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
            }
        }
    }

    private func chunked(_ items: [String], size: Int) -> [[String]] {
        stride(from: 0, to: items.count, by: size).map {
            Array(items[$0 ..< min($0 + size, items.count)])
        }
    }
}

// MARK: - Conversation Timeline View

/// Displays transcript segments as an ordered conversation timeline.
/// Each segment shows a time offset, speaker label, and the spoken text.
///
///   [00:03] Me: Hello everyone.
///   [00:10] Participant: Good morning.
///   [00:18] Me: Let's get started.
///
/// Replaces the flat `TextEditor` when timeline segments are available.
/// The user can switch back to Full Transcript via the mode picker.
private struct ConversationTimelineView: View {
    @Environment(\.colorScheme) private var colorScheme
    let segments: [TranscriptSegment]
    let meetingStart: Date

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(segments) { segment in
                    TimelineSegmentRow(
                        segment: segment,
                        meetingStart: meetingStart
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 220)
        .background(OrinColor.backgroundSecondary(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TimelineSegmentRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let segment: TranscriptSegment
    let meetingStart: Date

    private var isMic: Bool { segment.source == "mic" }

    private var timeOffset: String {
        let s = max(0, Int(segment.timestamp.timeIntervalSince(meetingStart)))
        let m = s / 60, sec = s % 60
        return String(format: "%02d:%02d", m, sec)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Time offset badge
            Text(timeOffset)
                .font(.system(size: 10, weight: .medium).monospaced())
                .foregroundStyle(OrinColor.secondaryText(colorScheme))
                .frame(width: 42, alignment: .trailing)
                .padding(.top, 2)

            // Speaker indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(isMic ? OrinColor.accent : Color.secondary.opacity(0.5))
                .frame(width: 3)
                .padding(.top, 3)
                .padding(.bottom, 3)

            // Speaker label + text
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.speakerLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isMic ? OrinColor.accent : OrinColor.secondaryText(colorScheme))
                Text(segment.text)
                    .font(.system(size: 13))
                    .foregroundStyle(OrinColor.primaryText(colorScheme))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

// MARK: - Calendar-only Event Row

/// Shows an EKEvent that has no corresponding MeetingItem yet.
/// Tapping "Open" creates a MeetingItem linked to this event.
private struct CalendarOnlyEventRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let event: EKEvent
    var onCreate: () -> Void

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: event.startDate))–\(f.string(from: event.endDate))"
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Meeting")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OrinColor.primaryText(colorScheme))
                    .lineLimit(1)
                Text(timeString)
                    .font(.system(size: 11))
                    .foregroundStyle(OrinColor.secondaryText(colorScheme))
            }
            Spacer()
            Button("Open") { onCreate() }
                .buttonStyle(OrinSecondaryButtonStyle())
                .font(.system(size: 11))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}

// RecurringFolderSuggestion removed — replaced by RecurringPattern from RecurringMeetingService.

private enum MeetingDeleteTarget {
    case transcript
    case recording
    case meeting
}

// MARK: - Transcript view mode

private enum TranscriptViewMode: String, CaseIterable {
    case timeline  = "Timeline"
    case legacy    = "Full Transcript"
}

private struct MeetingDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var meeting: MeetingItem
    let folders: [MeetingFolderItem]
    /// TranscriptSegments for this meeting (pre-filtered by the parent).
    let segments: [TranscriptSegment]
    var onExport: (MeetingExportFormat) -> Void
    var onMoveToFolder: (MeetingFolderItem?) -> Void

    @State private var isAnalyzing = false
    @State private var isImportingTranscript = false
    @State private var recordingService = ServiceContainer.shared.resolve(RecordingService.self)
    @State private var systemAudioService = ServiceContainer.shared.resolve(SystemAudioCaptureService.self)
    @State private var transcriptStore = ServiceContainer.shared.resolve(TranscriptStore.self)
    @State private var wasRecordingThisMeeting = false
    @State private var noActiveMeetingError = false
    @State private var pendingDelete: MeetingDeleteTarget?
    @State private var showingDeleteConfirm = false
    /// Defaults to timeline when segments exist; falls back to legacy automatically.
    @State private var transcriptViewMode: TranscriptViewMode = .timeline

    private let intelligence = ServiceContainer.shared.resolve(MeetingIntelligenceService.self)

    /// True when transcript segments are available for this meeting.
    private var hasTimeline: Bool { !segments.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    recordingCard
                    meetingQuickStats       // at-a-glance summary of meeting health
                    transcriptCard          // primary content — moved before summary
                    summaryCard
                    InsightCard(title: "Decisions", items: meeting.decisions)
                    InsightCard(title: "Action Items", items: meeting.actionItems)
                    commitmentsCard
                    suggestedTasksCard
                    participantsCard   // ← moved to bottom (less critical than content)
                }
                .padding(.trailing, 8)
            }
        }
        .padding(24)
        .background(OrinColor.backgroundPrimary(colorScheme))
        .onAppear {
            if recordingService.activeMeetingID == meeting.id {
                wasRecordingThisMeeting = true
                transcriptStore.beginSession(meetingID: meeting.id, meeting: meeting, context: modelContext)
            }
        }
        .onChange(of: recordingService.activeMeetingID) { _, newID in
            if newID == meeting.id {
                wasRecordingThisMeeting = true
                transcriptStore.beginSession(meetingID: meeting.id, meeting: meeting, context: modelContext)
            }
        }
        .onChange(of: recordingService.speakerTranscript) { _, labeled in
            guard wasRecordingThisMeeting else { return }
            transcriptStore.updateMic(labeled)
        }
        .onChange(of: systemAudioService.participantSpeakerTranscript) { _, labeled in
            guard wasRecordingThisMeeting else { return }
            transcriptStore.updateParticipant(labeled)
        }
        .onChange(of: recordingService.isRecording) { _, isNow in
            guard !isNow, wasRecordingThisMeeting else { return }
            wasRecordingThisMeeting = false
            let elapsed = TimeInterval(recordingService.elapsedSeconds)
            let audioURL = recordingService.recordingURL
            Task { @MainActor in
                await transcriptStore.finalize(elapsed: elapsed, audioURL: audioURL)
                // Auto-analysis for recordings started from MeetingDetailView.
                await autoAnalyzeIfEnabled(elapsed: elapsed)
            }
        }
        .fileImporter(
            isPresented: $isImportingTranscript,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            importTranscript(result)
        }
        .confirmationDialog("Delete meeting data?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            if pendingDelete == .transcript {
                Button("Delete Transcript", role: .destructive) { deleteTranscript() }
            }
            if pendingDelete == .recording {
                Button("Delete Recording", role: .destructive) { deleteRecording() }
            }
            if pendingDelete == .meeting {
                Button("Delete Full Meeting", role: .destructive) { deleteFullMeeting() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cleans database references and local files where applicable.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title)
                    .font(OrinFont.pageTitle)
                    .foregroundStyle(OrinColor.primaryText(colorScheme))
                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                    .font(OrinFont.body)
                    .foregroundStyle(OrinColor.secondaryText(colorScheme))
            }
            Spacer()
            Button {
                isImportingTranscript = true
            } label: {
                Label("Import", systemImage: "doc.badge.plus")
            }
            .buttonStyle(OrinSecondaryButtonStyle())

            Button {
                Task { await analyze() }
            } label: {
                Label(isAnalyzing ? "Analyzing" : "Analyze", systemImage: "sparkles")
            }
            .buttonStyle(OrinSecondaryButtonStyle())
            .disabled(isAnalyzing || meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Menu {
                Menu("Export") {
                    Button("JSON") { onExport(.json) }
                    Button("Markdown") { onExport(.markdown) }
                    Button("Text") { onExport(.text) }
                    Button("CSV") { onExport(.csv) }
                }
                Menu("Move to Folder") {
                    Button("Remove from Folder") { onMoveToFolder(nil) }
                    ForEach(folders) { folder in
                        Button(folder.name) { onMoveToFolder(folder) }
                    }
                }
                Divider()
                Button(role: .destructive) {
                    pendingDelete = .transcript
                    showingDeleteConfirm = true
                } label: {
                    Text("Delete Transcript")
                }
                Button(role: .destructive) {
                    pendingDelete = .recording
                    showingDeleteConfirm = true
                } label: {
                    Text("Delete Recording")
                }
                Button(role: .destructive) {
                    pendingDelete = .meeting
                    showingDeleteConfirm = true
                } label: {
                    Text("Delete Full Meeting")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
            }
            .menuStyle(.button)
        }
    }

    private var recordingCard: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Recording", systemImage: "mic")
                        .font(OrinFont.cardTitle)
                    Spacer()
                    if recordingService.isRecording {
                        Button {
                            recordingService.stopRecording()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(OrinSecondaryButtonStyle())
                    } else {
                        Button {
                            startRecording()
                        } label: {
                            Label("Start Recording", systemImage: "record.circle")
                        }
                        .buttonStyle(OrinSecondaryButtonStyle())
                    }
                }
                if let err = recordingService.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(OrinFont.caption)
                        .foregroundStyle(.orange)
                } else if recordingService.isRecording {
                    HStack {
                        Circle().fill(OrinColor.error).frame(width: 8, height: 8)
                        Text("Listening • \(recordingService.durationText)")
                            .font(OrinFont.body.weight(.semibold))
                    }
                } else if let path = meeting.audioFilePath {
                    Label("Audio saved: \(URL(fileURLWithPath: path).lastPathComponent)", systemImage: "waveform")
                        .font(OrinFont.caption)
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                } else {
                    Text("Not recording")
                        .font(OrinFont.body)
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                }
                if noActiveMeetingError {
                    Text("No active meeting detected. Start a meeting in your browser or app first.")
                        .font(OrinFont.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var participantsCard: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Participants").font(OrinFont.cardTitle)
                Text(meeting.participants.isEmpty ? "No participants added." : meeting.participants.joined(separator: ", "))
                    .font(OrinFont.body)
                    .foregroundStyle(meeting.participants.isEmpty ? OrinColor.secondaryText(colorScheme) : OrinColor.primaryText(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Quick Stats Bar
    //
    // At-a-glance meeting health summary shown directly below the recording card.
    // Eliminates the need to scroll through all cards to understand a meeting's state.

    @ViewBuilder
    private var meetingQuickStats: some View {
        let hasTranscript  = !meeting.transcript.isEmpty
        let hasSummary     = !meeting.summary.isEmpty
        let hasRecording   = meeting.audioFilePath != nil
        let actionCount    = meeting.actionItems.count
        let participantCount = meeting.participants.count
        let durationSecs   = meeting.durationSeconds

        if hasTranscript || hasSummary || hasRecording || durationSecs > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if durationSecs > 60 {
                        QuickStatChip(
                            icon: "clock",
                            label: durationSecs >= 3600
                                ? String(format: "%dh %dm", Int(durationSecs) / 3600, (Int(durationSecs) % 3600) / 60)
                                : "\(Int(durationSecs) / 60)m",
                            active: true,
                            accent: false
                        )
                    }
                    if participantCount > 0 {
                        QuickStatChip(icon: "person.2", label: "\(participantCount)", active: true, accent: false)
                    }
                    QuickStatChip(icon: "waveform",      label: "Recording",  active: hasRecording,  accent: hasRecording)
                    QuickStatChip(icon: "text.bubble",   label: "Transcript", active: hasTranscript, accent: hasTranscript)
                    QuickStatChip(icon: "sparkles",      label: "Analyzed",   active: hasSummary,    accent: hasSummary)
                    if actionCount > 0 {
                        QuickStatChip(icon: "checklist", label: "\(actionCount) action\(actionCount == 1 ? "" : "s")", active: true, accent: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(OrinColor.backgroundSecondary(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var transcriptCard: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Transcript").font(OrinFont.cardTitle)
                    Spacer()
                    if hasTimeline {
                        Picker("", selection: $transcriptViewMode) {
                            ForEach(TranscriptViewMode.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                    }
                }

                if hasTimeline && transcriptViewMode == .timeline {
                    ConversationTimelineView(
                        segments: segments,
                        meetingStart: meeting.date
                    )
                } else {
                    TextEditor(text: $meeting.transcript)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                        .background(OrinColor.backgroundSecondary(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .onAppear {
            // Default to legacy when no timeline segments are available
            if !hasTimeline { transcriptViewMode = .legacy }
        }
        .onChange(of: segments.count) { _, count in
            if count > 0 { transcriptViewMode = .timeline }
        }
    }

    private var summaryCard: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Summary").font(OrinFont.cardTitle)
                editableListText($meeting.summary, placeholder: "No summary yet.")
            }
        }
    }

    private var commitmentsCard: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Commitments").font(OrinFont.cardTitle)
                if meeting.commitments.isEmpty {
                    Text("No commitments detected yet.")
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                } else {
                    ForEach(meeting.commitments) { commitment in
                        HStack {
                            Image(systemName: commitment.statusValue == "fulfilled" ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(commitment.statusValue == "fulfilled" ? .green : .secondary)
                            Text(commitment.title)
                            Spacer()
                            Button(commitment.statusValue == "fulfilled" ? "Reopen" : "Fulfill") {
                                commitment.statusValue = commitment.statusValue == "fulfilled" ? "open" : "fulfilled"
                                modelContext.safeSave(context: "commitment")
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var suggestedTasksCard: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Suggested Tasks").font(OrinFont.cardTitle)
                if meeting.suggestedTaskTitles.isEmpty {
                    Text("No suggested tasks yet.")
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                } else {
                    ForEach(meeting.suggestedTaskTitles, id: \.self) { title in
                        HStack {
                            Text(title)
                            Spacer()
                            if meeting.acceptedSuggestedTaskTitles.contains(title) {
                                Label("Accepted", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(OrinFont.caption)
                            } else {
                                Button("Accept") { acceptSuggestedTask(title) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func editableListText(_ text: Binding<String>, placeholder: String) -> some View {
        if text.wrappedValue.isEmpty {
            Text(placeholder)
                .foregroundStyle(OrinColor.secondaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextEditor(text: text)
                .frame(minHeight: 100)
                .scrollContentBackground(.hidden)
                .background(OrinColor.backgroundSecondary(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func startRecording() {
        Task {
            await recordingService.startRecording(for: meeting.id)
            guard recordingService.isRecording else {
                noActiveMeetingError = false
                return
            }
            // Begin TranscriptStore session AFTER recording is confirmed running.
            noActiveMeetingError = false
            wasRecordingThisMeeting = true
            transcriptStore.beginSession(meetingID: meeting.id, meeting: meeting, context: modelContext)
            await systemAudioService.startCapturing(for: meeting.id)
        }
    }

    private func analyze() async {
        isAnalyzing = true
        // Prefer segment-based analysis (conversation timeline) when available.
        let analysis: MeetingAnalysis
        if !segments.isEmpty {
            analysis = await intelligence.analyze(
                title: meeting.title,
                segments: segments,
                meetingStart: meeting.date,
                fallbackTranscript: meeting.transcript
            )
        } else {
            analysis = await intelligence.analyze(title: meeting.title, transcript: meeting.transcript)
        }
        meeting.summary              = analysis.summary
        meeting.decisions            = analysis.decisions
        meeting.actionItems          = analysis.actionItems
        meeting.suggestedTaskTitles  = analysis.suggestedTasks
        meeting.commitments          = analysis.commitments.map { CommitmentItem(title: $0) }
        modelContext.safeSave(context: "meeting analysis")
        isAnalyzing = false
    }

    /// Runs analysis automatically after recording stops if the `orin.meetings.autoAnalyze`
    /// setting is enabled and the elapsed time meets the minimum duration threshold.
    @MainActor
    private func autoAnalyzeIfEnabled(elapsed: TimeInterval) async {
        guard UserDefaults.standard.bool(forKey: "orin.meetings.autoAnalyze") else { return }
        let minMinutes = max(1, UserDefaults.standard.integer(forKey: "orin.meetings.minDurationMinutes"))
        guard elapsed >= TimeInterval(minMinutes * 60) else { return }
        guard !meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await analyze()
    }

    private func acceptSuggestedTask(_ title: String) {
        let task = TaskItem(
            title: title,
            taskDescription: "Suggested from \(meeting.title)",
            priority: .p2Medium,
            dueDate: Calendar.current.startOfDay(for: Date())
        )
        task.linkedMeeting = meeting
        meeting.acceptedSuggestedTaskTitles.append(title)
        modelContext.insert(task)
        modelContext.safeSave(context: "task from meeting")
    }

    private func importTranscript(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                ErrorManager.shared.report(.storageLoadFailed(context: "transcript"))
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            meeting.transcript = try String(contentsOf: url, encoding: .utf8)
            meeting.transcriptDeletedAt = nil
            modelContext.safeSave(context: "meeting transcript")
        } catch {
            ErrorManager.shared.report(.storageLoadFailed(context: "transcript"))
        }
    }

    private func deleteTranscript() {
        meeting.transcript = ""
        meeting.transcriptDeletedAt = Date()
        // Also remove TranscriptChunk + TranscriptSegment records so storage is freed
        let mid = meeting.id
        let chunks = (try? modelContext.fetch(FetchDescriptor<TranscriptChunk>())) ?? []
        chunks.filter { $0.meetingId == mid }.forEach { modelContext.delete($0) }
        let segs = (try? modelContext.fetch(FetchDescriptor<TranscriptSegment>())) ?? []
        segs.filter { $0.meetingId == mid }.forEach { modelContext.delete($0) }
        modelContext.safeSave(context: "meeting transcript delete")
    }

    private func deleteRecording() {
        if let path = meeting.audioFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        meeting.audioFilePath = nil
        meeting.recordingDeletedAt = Date()
        modelContext.safeSave(context: "meeting recording delete")
    }

    private func deleteFullMeeting() {
        modelContext.deleteMeetingFully(meeting)
        modelContext.safeSave(context: "meeting full delete")
    }
}

// MARK: - Quick Stat Chip

private struct QuickStatChip: View {
    let icon: String
    let label: String
    let active: Bool
    let accent: Bool  // when true, uses accent colour instead of secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(active ? (accent ? OrinColor.accent : Color.primary) : Color.secondary.opacity(0.5))
        .opacity(active ? 1 : 0.5)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            active
                ? (accent ? OrinColor.accent.opacity(0.12) : Color.secondary.opacity(0.1))
                : Color.secondary.opacity(0.05)
        )
        .clipShape(Capsule())
    }
}

private struct InsightCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let items: [String]

    var body: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(OrinFont.cardTitle)
                if items.isEmpty {
                    Text("No \(title.lowercased()) detected yet.")
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                } else {
                    ForEach(items, id: \.self) { item in
                        Label(item, systemImage: "smallcircle.filled.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MeetingDraft {
    var title = ""
    var date = Date()
    var participants = ""

    var participantsList: [String] {
        participants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct MeetingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MeetingDraft()

    var onSave: (MeetingDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Meeting")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Title", text: $draft.title)
                DatePicker("Date", selection: $draft.date)
                TextField("Participants", text: $draft.participants)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
