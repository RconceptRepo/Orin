import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MeetingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MeetingItem.date, order: .reverse)
    private var meetings: [MeetingItem]

    @State private var selectedMeetingID: UUID?
    @State private var isCreatingMeeting = false

    private var selectedMeeting: MeetingItem? {
        meetings.first { $0.id == selectedMeetingID }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Meetings")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        isCreatingMeeting = true
                    } label: {
                        Label("New Meeting", systemImage: "plus")
                    }
                }

                List(meetings, selection: $selectedMeetingID) { meeting in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title)
                            .font(.body)
                        Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(meeting.id)
                }
            }
            .padding()
            .frame(minWidth: 260)

            if let selectedMeeting {
                MeetingDetailView(meeting: selectedMeeting)
                    .frame(minWidth: 560)
            } else {
                ContentUnavailableView(
                    "No Meeting Selected",
                    systemImage: "video",
                    description: Text("Create or select a meeting to capture transcript, commitments, and tasks.")
                )
                .frame(minWidth: 560)
            }
        }
        .sheet(isPresented: $isCreatingMeeting) {
            MeetingEditorView { draft in
                let meeting = MeetingItem(title: draft.title, date: draft.date)
                meeting.participants = draft.participantsList
                modelContext.insert(meeting)
                modelContext.safeSave(context: "meeting")
                selectedMeetingID = meeting.id
            }
        }
    }
}

private struct MeetingDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var meeting: MeetingItem

    @State private var isAnalyzing = false
    @State private var isImportingTranscript = false
    @State private var recordingService    = ServiceContainer.shared.resolve(RecordingService.self)
    @State private var meetingDetector     = ServiceContainer.shared.resolve(MeetingDetectorService.self)
    @State private var systemAudioService  = ServiceContainer.shared.resolve(SystemAudioCaptureService.self)
    @State private var transcriptStore     = ServiceContainer.shared.resolve(TranscriptStore.self)
    @State private var wasRecordingThisMeeting = false
    /// Set when the user taps "Start Recording" with no meeting detected.
    @State private var noActiveMeetingError = false

    private let intelligence = ServiceContainer.shared.resolve(MeetingIntelligenceService.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.title2.weight(.semibold))
                    Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    isImportingTranscript = true
                } label: {
                    Label("Import", systemImage: "doc.badge.plus")
                }

                Button {
                    Task { await analyze() }
                } label: {
                    Label(isAnalyzing ? "Analyzing" : "Analyze", systemImage: "sparkles")
                }
                .disabled(isAnalyzing || meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Recording controls
                    GroupBox {
                        if let err = recordingService.errorMessage {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Text(err).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Dismiss") { recordingService.clearError() }.font(.caption)
                            }
                        } else if recordingService.isRecording {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Circle().fill(.red).frame(width: 8, height: 8)
                                    Text("Recording • \(recordingService.durationText)")
                                        .font(.body.weight(.semibold))
                                    Spacer()
                                    Button("Stop Recording") {
                                        recordingService.stopRecording()
                                    }
                                }
                                if !recordingService.speakerTranscript.isEmpty {
                                    Text(recordingService.speakerTranscript)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    if let path = meeting.audioFilePath {
                                        Label("Audio saved: \(URL(fileURLWithPath: path).lastPathComponent)", systemImage: "waveform")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Not recording").foregroundStyle(.secondary).font(.body)
                                    }
                                    Spacer()
                                    // Part 4: block recording when no meeting platform is detected.
                                    // meetingDetector.detectedMeetingApp is nil between meetings.
                                    Button {
                                        guard meetingDetector.detectedMeetingApp != nil else {
                                            noActiveMeetingError = true
                                            print("[Recording] manual start blocked — no active meeting detected for '\(meeting.title)'")
                                            return
                                        }
                                        noActiveMeetingError = false
                                        wasRecordingThisMeeting = true
                                        print("[Recording] manual start approved meeting='\(meeting.title)' platform=\(meetingDetector.detectedMeetingApp ?? "?")")
                                        Task {
                                            await recordingService.startRecording(for: meeting.id)
                                            // Start system audio after mic is confirmed running
                                            if recordingService.isRecording {
                                                await systemAudioService.startCapturing(for: meeting.id)
                                            }
                                        }
                                    } label: {
                                        Label("Start Recording", systemImage: "record.circle")
                                    }
                                }
                                if noActiveMeetingError {
                                    Text("No active meeting detected. Start a meeting in your browser or app first.")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    } label: {
                        Label("Recording", systemImage: "mic")
                            .font(.headline)
                    }

                    GroupBox("Participants") {
                        if meeting.participants.isEmpty {
                            Text("No participants added.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(meeting.participants.joined(separator: ", "))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    GroupBox("Transcript") {
                        TextEditor(text: $meeting.transcript)
                            .font(.body.monospaced())
                            .frame(minHeight: 180)
                    }

                    GroupBox("Summary") {
                        editableListText($meeting.summary, placeholder: "No summary yet.")
                    }

                    InsightList(title: "Decisions", items: meeting.decisions)
                    InsightList(title: "Action Items", items: meeting.actionItems)

                    GroupBox("Commitments") {
                        if meeting.commitments.isEmpty {
                            Text("No commitments detected yet.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
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
                    }

                    GroupBox("Suggested Tasks") {
                        if meeting.suggestedTaskTitles.isEmpty {
                            Text("No suggested tasks yet.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(meeting.suggestedTaskTitles, id: \.self) { title in
                                    HStack {
                                        Text(title)
                                        Spacer()
                                        if meeting.acceptedSuggestedTaskTitles.contains(title) {
                                            Label("Accepted", systemImage: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                                .font(.caption)
                                        } else {
                                            Button("Accept") {
                                                acceptSuggestedTask(title)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding()
        .onAppear {
            if recordingService.activeMeetingID == meeting.id {
                print("[Recording] MeetingDetailView appeared — recording already in progress meetingID=\(meeting.id)")
                wasRecordingThisMeeting = true
                // Ensure TranscriptStore session is active — idempotent if MainContainerView already
                // called beginSession for a prompt-triggered recording.
                transcriptStore.beginSession(
                    meetingID: meeting.id,
                    meeting: meeting,
                    context: modelContext
                )
            }
        }
        .onChange(of: recordingService.activeMeetingID) { _, newID in
            if newID == meeting.id {
                print("[Recording] activeMeetingID now matches this view meetingID=\(meeting.id)")
                wasRecordingThisMeeting = true
                // beginSession is idempotent — safe for both manual and prompt-triggered starts.
                transcriptStore.beginSession(
                    meetingID: meeting.id,
                    meeting: meeting,
                    context: modelContext
                )
            }
        }
        // Route mic chunks to TranscriptStore — empty-overwrite protection and merge happen there.
        .onChange(of: recordingService.speakerTranscript) { _, labeled in
            guard wasRecordingThisMeeting else { return }
            transcriptStore.updateMic(labeled)
        }
        // Route participant chunks to TranscriptStore.
        .onChange(of: systemAudioService.participantSpeakerTranscript) { _, labeled in
            guard wasRecordingThisMeeting else { return }
            transcriptStore.updateParticipant(labeled)
        }
        // Finalize via TranscriptStore on recording end — idempotent, safe to call from both
        // MainContainerView (prompt-triggered) and MeetingDetailView (manual-triggered).
        .onChange(of: recordingService.isRecording) { _, isNow in
            guard !isNow, wasRecordingThisMeeting else { return }
            wasRecordingThisMeeting = false
            print("[Transcript] MeetingDetail: delegating finalization to TranscriptStore meeting=\(meeting.id)")

            let elapsed = TimeInterval(recordingService.elapsedSeconds)
            let audioURL = recordingService.recordingURL
            Task { @MainActor in
                await transcriptStore.finalize(elapsed: elapsed, audioURL: audioURL)
                print("[Transcript] MeetingDetail: TranscriptStore.finalize complete meeting=\(meeting.id)")
            }
        }
        .fileImporter(
            isPresented: $isImportingTranscript,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            importTranscript(result)
        }
    }

    @ViewBuilder
    private func editableListText(_ text: Binding<String>, placeholder: String) -> some View {
        if text.wrappedValue.isEmpty {
            Text(placeholder)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextEditor(text: text)
                .frame(minHeight: 90)
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
            modelContext.safeSave(context: "meeting transcript")
        } catch {
            ErrorManager.shared.report(.storageLoadFailed(context: "transcript"))
        }
    }
}

private struct InsightList: View {
    let title: String
    let items: [String]

    var body: some View {
        GroupBox(title) {
            if items.isEmpty {
                Text("No \(title.lowercased()) detected yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        Label(item, systemImage: "smallcircle.filled.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
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
