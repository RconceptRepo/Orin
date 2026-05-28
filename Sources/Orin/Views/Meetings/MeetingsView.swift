import AppKit
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

    @State private var selectedMeetingID: UUID?
    @State private var isCreatingMeeting = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var importStatus: String?
    @State private var noActiveMeetingError = false
    @State private var recurringSuggestion: RecurringFolderSuggestion?

    @State private var selectedMeetingIDs: Set<UUID> = []
    @State private var isPastExpanded = false
    @State private var isUpcomingExpanded = true

    @State private var recordingService = ServiceContainer.shared.resolve(RecordingService.self)
    @State private var meetingDetector = ServiceContainer.shared.resolve(MeetingDetectorService.self)
    @State private var systemAudioService = ServiceContainer.shared.resolve(SystemAudioCaptureService.self)
    @State private var transcriptStore = ServiceContainer.shared.resolve(TranscriptStore.self)

    private let dataService = ServiceContainer.shared.resolve(MeetingDataService.self)

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

            if let selectedMeeting {
                MeetingDetailView(
                    meeting: selectedMeeting,
                    folders: folders,
                    onExport: { export(meeting: selectedMeeting, format: $0) },
                    onMoveToFolder: { folder in move(selectedMeeting, to: folder) }
                )
                .frame(minWidth: 620, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Meeting Selected",
                    systemImage: "video",
                    description: Text("Create or select a meeting to capture transcript, commitments, and tasks.")
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
            refreshRecurringSuggestion()
        }
        .onChange(of: allMeetings.count) { _, _ in
            refreshRecurringSuggestion()
        }
        .alert(
            "Create recurring meeting folder?",
            isPresented: Binding(
                get: { recurringSuggestion != nil },
                set: { if !$0 { recurringSuggestion = nil } }
            )
        ) {
            Button("Create Folder") { acceptRecurringSuggestion() }
            Button("Dismiss", role: .cancel) {
                if let recurringSuggestion {
                    UserDefaults.standard.set(true, forKey: recurringSuggestion.dismissedKey)
                }
                recurringSuggestion = nil
            }
        } message: {
            Text(recurringSuggestion?.message ?? "")
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

            ScrollView {
                LazyVStack(spacing: 2) {
                    comingUpSection
                    folderBlocksSection
                    pastSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, selectedMeetingIDs.isEmpty ? 20 : 72)
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
            // Section header
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
                if upcomingMeetings.isEmpty {
                    Text("No upcoming meetings.")
                        .font(.system(size: 13))
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                } else {
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
                onSelect: { selectedMeetingID = $0.id },
                onRecord: { startManualRecording(for: $0) },
                onExport: { export(meeting: $0, format: $1) },
                onMoveToFolder: { move($0, to: $1) },
                onCreateFolder: { isCreatingFolder = true },
                onDeleteFolder: { deleteFolder(folder) },
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
                let pastMeetings = pastUnfiled
                if pastMeetings.isEmpty {
                    Text("No past meetings.")
                        .font(.system(size: 13))
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                } else {
                    let groups = groupByDay(pastMeetings.reversed())
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

    private var upcomingUnfiled: [MeetingItem] {
        let today = Calendar.current.startOfDay(for: Date())
        return unfiledMeetings
            .filter { $0.date >= today }
            .sorted { $0.date < $1.date }
    }

    private var pastUnfiled: [MeetingItem] {
        let today = Calendar.current.startOfDay(for: Date())
        return unfiledMeetings
            .filter { $0.date < today }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Day grouping

    private struct DayGroup {
        let date: Date
        let meetings: [MeetingItem]
    }

    private func groupByDay(_ items: [MeetingItem]) -> [DayGroup] {
        let cal = Calendar.current
        var result: [Date: [MeetingItem]] = [:]
        for item in items {
            let day = cal.startOfDay(for: item.date)
            result[day, default: []].append(item)
        }
        return result.keys.sorted().map { day in
            DayGroup(date: day, meetings: result[day]!.sorted { $0.date < $1.date })
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
        guard meetingDetector.detectedMeetingApp != nil else {
            noActiveMeetingError = true
            importStatus = "No active meeting detected. Open a Meet, Teams, Zoom, or browser meeting first."
            return
        }
        noActiveMeetingError = false
        selectedMeetingID = meeting.id
        transcriptStore.beginSession(meetingID: meeting.id, meeting: meeting, context: modelContext)
        Task {
            await recordingService.startRecording(for: meeting.id)
            if recordingService.isRecording {
                await systemAudioService.startCapturing(for: meeting.id)
            }
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
        removeRecordingFile(for: meeting)
        modelContext.delete(meeting)
        if selectedMeetingID == meeting.id { selectedMeetingID = nil }
        modelContext.safeSave(context: "meeting delete")
    }

    private func refreshRecurringSuggestion() {
        guard recurringSuggestion == nil else { return }
        let grouped = Dictionary(grouping: unfiledMeetings) { meeting in
            recurringSignature(for: meeting)
        }
        guard let candidate = grouped
            .filter({ !$0.key.isEmpty && $0.value.count >= 2 })
            .sorted(by: { $0.value.count > $1.value.count })
            .first
        else { return }

        let title = candidate.value.first?.title ?? "Recurring Meeting"
        let dismissedKey = "orin.recurringFolderSuggestion.dismissed.\(candidate.key)"
        guard !UserDefaults.standard.bool(forKey: dismissedKey) else { return }
        guard !folders.contains(where: { $0.name.caseInsensitiveCompare(title) == .orderedSame }) else { return }

        recurringSuggestion = RecurringFolderSuggestion(
            signature: candidate.key,
            title: title,
            meetingIDs: candidate.value.map(\.id),
            dismissedKey: dismissedKey
        )
    }

    private func acceptRecurringSuggestion() {
        guard let suggestion = recurringSuggestion else { return }
        let folder = MeetingFolderItem(name: suggestion.title, sortIndex: folders.count)
        modelContext.insert(folder)
        for meeting in meetings where suggestion.meetingIDs.contains(meeting.id) {
            meeting.folderID = folder.id
        }
        modelContext.safeSave(context: "recurring meeting folder")
        recurringSuggestion = nil
    }

    private func recurringSignature(for meeting: MeetingItem) -> String {
        let normalizedTitle = meeting.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedParticipants = meeting.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "|")
        guard !normalizedTitle.isEmpty else { return "" }
        return "\(normalizedTitle)#\(normalizedParticipants)"
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
    var onSelect: (MeetingItem) -> Void
    var onRecord: (MeetingItem) -> Void
    var onExport: (MeetingItem, MeetingExportFormat) -> Void
    var onMoveToFolder: (MeetingItem, MeetingFolderItem?) -> Void
    var onCreateFolder: () -> Void
    var onDeleteFolder: () -> Void
    var onDeleteMeeting: (MeetingItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Folder header row
            HStack {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Image(systemName: "folder.fill")
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
                    Button("Rename Folder") { /* trigger rename */ }
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

            // Document icon
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))

            // Title + participants
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? OrinColor.accent : OrinColor.primaryText(colorScheme))
                    .lineLimit(1)
                Text(meeting.participants.isEmpty
                     ? "Me"
                     : meeting.participants.prefix(2).joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

private struct RecurringFolderSuggestion {
    let signature: String
    let title: String
    let meetingIDs: [UUID]
    let dismissedKey: String

    var message: String {
        "Orin found \(meetingIDs.count) matching meetings named \"\(title)\"."
    }
}

private enum MeetingDeleteTarget {
    case transcript
    case recording
    case meeting
}

private struct MeetingDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var meeting: MeetingItem
    let folders: [MeetingFolderItem]
    var onExport: (MeetingExportFormat) -> Void
    var onMoveToFolder: (MeetingFolderItem?) -> Void

    @State private var isAnalyzing = false
    @State private var isImportingTranscript = false
    @State private var recordingService = ServiceContainer.shared.resolve(RecordingService.self)
    @State private var meetingDetector = ServiceContainer.shared.resolve(MeetingDetectorService.self)
    @State private var systemAudioService = ServiceContainer.shared.resolve(SystemAudioCaptureService.self)
    @State private var transcriptStore = ServiceContainer.shared.resolve(TranscriptStore.self)
    @State private var wasRecordingThisMeeting = false
    @State private var noActiveMeetingError = false
    @State private var pendingDelete: MeetingDeleteTarget?
    @State private var showingDeleteConfirm = false

    private let intelligence = ServiceContainer.shared.resolve(MeetingIntelligenceService.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    recordingCard
                    participantsCard
                    transcriptCard
                    summaryCard
                    InsightCard(title: "Decisions", items: meeting.decisions)
                    InsightCard(title: "Action Items", items: meeting.actionItems)
                    commitmentsCard
                    suggestedTasksCard
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

    private var transcriptCard: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Transcript").font(OrinFont.cardTitle)
                TextEditor(text: $meeting.transcript)
                    .font(.body.monospaced())
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .background(OrinColor.backgroundSecondary(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
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
        guard meetingDetector.detectedMeetingApp != nil else {
            noActiveMeetingError = true
            return
        }
        noActiveMeetingError = false
        wasRecordingThisMeeting = true
        transcriptStore.beginSession(meetingID: meeting.id, meeting: meeting, context: modelContext)
        Task {
            await recordingService.startRecording(for: meeting.id)
            if recordingService.isRecording {
                await systemAudioService.startCapturing(for: meeting.id)
            }
        }
    }

    private func analyze() async {
        isAnalyzing = true
        let analysis = await intelligence.analyze(title: meeting.title, transcript: meeting.transcript)
        meeting.summary = analysis.summary
        meeting.decisions = analysis.decisions
        meeting.actionItems = analysis.actionItems
        meeting.suggestedTaskTitles = analysis.suggestedTasks
        meeting.commitments = analysis.commitments.map { CommitmentItem(title: $0) }
        modelContext.safeSave(context: "meeting analysis")
        isAnalyzing = false
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
        deleteRecording()
        modelContext.delete(meeting)
        modelContext.safeSave(context: "meeting full delete")
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
