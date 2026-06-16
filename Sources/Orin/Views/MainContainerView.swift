import SwiftData
import SwiftUI

struct MainContainerView: View {
    @AppStorage("orin.theme.mode") private var themeModeRawValue = OrinThemeMode.system.rawValue
    @AppStorage("orin.calendar.backgroundSync") private var calendarBackgroundSync = true
    @AppStorage("orin.sidebar.collapsed") private var isSidebarCollapsed = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedModule: SidebarModule = .today
    @State private var recordingService = ServiceContainer.shared.resolve(RecordingService.self)
    @State private var meetingDetector = ServiceContainer.shared.resolve(MeetingDetectorService.self)
    @State private var calendarService = ServiceContainer.shared.resolve(CalendarService.self)
    @State private var systemAudioService = ServiceContainer.shared.resolve(SystemAudioCaptureService.self)
    @State private var transcriptStore = ServiceContainer.shared.resolve(TranscriptStore.self)
    @State private var notificationService = ServiceContainer.shared.resolve(MeetingNotificationService.self)
    @State private var activeRecordingMeeting: MeetingItem?
    private let intelligence = ServiceContainer.shared.resolve(MeetingIntelligenceService.self)

    enum SidebarModule: Hashable, CaseIterable {
        case today
        case allTasks
        case calendar
        case meetings
        case backlog
        case vault
        case settings

        var iconName: String {
            switch self {
            case .today: "sun.max"
            case .allTasks: "list.bullet"
            case .calendar: "calendar"
            case .meetings: "video"
            case .backlog: "archivebox"
            case .vault: "lock.shield"
            case .settings: "gearshape"
            }
        }

        var title: String {
            switch self {
            case .today: "Today"
            case .allTasks: "All Tasks"
            case .calendar: "Calendar"
            case .meetings: "Meetings"
            case .backlog: "Backlog"
            case .vault: "Vault"
            case .settings: "Settings"
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: sidebarWidth(for: proxy.size.width))

                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(OrinColor.backgroundPrimary(colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .trailing, spacing: 14) {
                    if meetingDetector.shouldShowRecordingPrompt, let appName = meetingDetector.detectedMeetingApp {
                        MeetingRecordingPromptView(
                            appName: appName,
                            onStart: {
                                Task { @MainActor in
                                    await startRecordingFromDetectedMeeting()
                                }
                            },
                            onDismiss: {
                                meetingDetector.dismissPrompt()
                            }
                        )
                    }

                }
                .padding(24)
            }
        }
        .frame(minWidth: 1280, minHeight: 720)
        .background(OrinColor.backgroundPrimary(colorScheme))
        .preferredColorScheme(OrinThemeMode(rawValue: themeModeRawValue)?.colorScheme)
        .errorHandlingOverlay()
        .onAppear {
            notificationService.configure()
            meetingDetector.startMonitoring()
            meetingDetector.onMeetingDetected = { appName in
                notificationService.notifyMeetingDetected(appName: appName)
            }

            // Auto-stop: when the meeting disappears from the detection window,
            // stop recording only when BOTH conditions are met:
            //   1. Meeting no longer detected (this closure fires)
            //   2. Audio has been inactive for at least audioInactivityThreshold seconds
            //
            // This prevents a brief network blip or process hiccup from stopping an
            // active recording.  The closure is set once; re-appearing re-registers
            // (last writer wins — always the same closure).
            meetingDetector.onMeetingEnded = {
                Task { @MainActor in
                    guard recordingService.isRecording else { return }

                    // Grace period 1 — allow the meeting to re-enter the detection window
                    // (e.g., Zoom briefly restarting its process, Chrome tab reload).
                    // Combined with the 3 s fast-poll this gives ≤ 4.5 s before reaching
                    // the audio-inactivity check.
                    print("[AutoStop] meeting ended while recording — 1.5 s initial grace")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard recordingService.isRecording else {
                        print("[AutoStop] recording stopped during grace — no action")
                        return
                    }

                    // Grace period 2 — audio-inactivity check.
                    // Configurable threshold (default 30 s).  If new transcript text arrived
                    // within the threshold, the mic/system audio is still active and we defer
                    // the stop by re-scheduling the next poll cycle instead of stopping now.
                    let audioInactivityThreshold: TimeInterval = 30
                    if let secondsSince = transcriptStore.secondsSinceLastUpdate,
                       secondsSince < audioInactivityThreshold {
                        print("[AutoStop] audio still active \(Int(secondsSince))s ago (threshold \(Int(audioInactivityThreshold))s) — deferring auto-stop")
                        return
                    }

                    print("[AutoStop] meeting gone + audio inactive — stopping recording")
                    recordingService.stopRecording()
                }
            }

            calendarService.refreshAuthorizationStatus()
            if calendarBackgroundSync {
                calendarService.startBackgroundSync()
            }
            // Check for recording action queued while the app was in the background.
            processPendingNotificationAction()
        }
        // Re-check the pending action whenever the app transitions to active (e.g.,
        // user tapped "Start Recording" on a notification while Orin was backgrounded).
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                processPendingNotificationAction()
            }
        }
        .onChange(of: recordingService.isRecording) { _, isNow in
            if isNow {
                // ── Recording started ─────────────────────────────────────────
                print("[Recording] MainContainerView: recording started — fast poll + system audio + TranscriptStore session")
                meetingDetector.enableFastPoll()
                notificationService.notifyRecordingActive()
                FloatingRecordingWidgetWindowManager.shared.show(recordingService: recordingService) {
                    recordingService.stopRecording()
                }

                // Start system audio capture for participant labeling (if not already started
                // by the onStart handler above). Guard inside startCapturing prevents double-start.
                Task { @MainActor in
                    await systemAudioService.startCapturing(for: activeRecordingMeeting?.id)
                }

                // Begin a TranscriptStore session for prompt-triggered recordings where
                // MainContainerView owns the meeting reference.  Manual recordings (started
                // from MeetingDetailView) call beginSession themselves via onChange(of: activeMeetingID).
                if let meeting = activeRecordingMeeting {
                    transcriptStore.beginSession(
                        meetingID: meeting.id,
                        meeting: meeting,
                        context: modelContext
                    )
                    print("[Transcript] MainContainer: TranscriptStore session begun for \(meeting.id)")
                }
            } else {
                // ── Recording stopped ─────────────────────────────────────────
                print("[Recording] MainContainerView: recording stopped — disabling fast poll + finalizing")
                meetingDetector.disableFastPoll()
                systemAudioService.stopCapturing()
                FloatingRecordingWidgetWindowManager.shared.hide()
                // Clear the persistent "Recording in Progress" notification (BUG-12).
                notificationService.notifyRecordingStopped()

                let elapsed = TimeInterval(recordingService.elapsedSeconds)
                let audioURL = recordingService.recordingURL
                // Capture meeting reference BEFORE clearing so auto-analysis can use it.
                let meetingForAnalysis = activeRecordingMeeting
                activeRecordingMeeting = nil

                // Delegate finalization to TranscriptStore — idempotent, best-of-N selection,
                // 1.5 s wait for trailing recognition chunks, integrity-checked save.
                Task { @MainActor in
                    await transcriptStore.finalize(elapsed: elapsed, audioURL: audioURL)
                    print("[Transcript] MainContainer: TranscriptStore.finalize complete")

                    // Auto-analysis: run if the setting is enabled and meeting was long enough.
                    await autoAnalyzeIfEnabled(meeting: meetingForAnalysis, elapsed: elapsed)
                }
            }
        }
        // Route mic transcript chunks into TranscriptStore on every recognition update.
        // Skipped when the SpeechTranscriber mic pipeline is active — that pipeline
        // calls updateMic() directly, and the view observer would produce a redundant
        // duplicate write on every result.
        .onChange(of: recordingService.speakerTranscript) { _, labeled in
            guard !FeatureFlags.useNewMicPipeline else { return }
            transcriptStore.updateMic(labeled)
        }
        // Route participant transcript chunks into TranscriptStore on every recognition update.
        // Skipped when the SpeechTranscriber participant pipeline is active — the legacy
        // self.transcript property (source of participantSpeakerTranscript) is still
        // mutated by the legacy recognizer when it runs, and without this guard, every
        // legacy callback overwrites the ST pipeline's accumulated TranscriptStore content.
        .onChange(of: systemAudioService.participantSpeakerTranscript) { _, labeled in
            guard !FeatureFlags.useNewParticipantPipeline else { return }
            transcriptStore.updateParticipant(labeled)
        }
        .onChange(of: calendarBackgroundSync) { _, enabled in
            if enabled {
                calendarService.startBackgroundSync()
            } else {
                calendarService.stopBackgroundSync()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orinNotificationStartRecording)) { _ in
            Task { @MainActor in
                await startRecordingFromDetectedMeeting()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orinNotificationDismissMeeting)) { _ in
            meetingDetector.dismissPrompt()
        }
        .onReceive(NotificationCenter.default.publisher(for: .orinNotificationStopRecording)) { _ in
            recordingService.stopRecording()
        }
    }

    private func sidebarWidth(for totalWidth: CGFloat) -> CGFloat {
        if isSidebarCollapsed {
            return max(72, totalWidth * 0.05)
        }
        return max(240, totalWidth * 0.2)
    }

    // MARK: - Auto-analysis

    /// Runs meeting intelligence analysis after recording if the user has enabled
    /// auto-analyze AND the meeting duration meets the minimum threshold.
    ///
    /// - Parameters:
    ///   - meeting: The `MeetingItem` that was just recorded.  `nil` when the recording
    ///     was started from `MeetingDetailView` (which has its own analysis path).
    ///   - elapsed: Actual recording duration in seconds.
    @MainActor
    private func autoAnalyzeIfEnabled(meeting: MeetingItem?, elapsed: TimeInterval) async {
        guard UserDefaults.standard.bool(forKey: "orin.meetings.autoAnalyze") else { return }
        guard let meeting else { return }

        let minMinutes = max(1, UserDefaults.standard.integer(forKey: "orin.meetings.minDurationMinutes"))
        let minSeconds = TimeInterval(minMinutes * 60)
        guard elapsed >= minSeconds else {
            print("[AutoAnalysis] skipped — elapsed \(Int(elapsed))s < minimum \(Int(minSeconds))s")
            return
        }
        guard !meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[AutoAnalysis] skipped — transcript is empty")
            return
        }

        // Fetch segments for this meeting. TranscriptStore.finalize() has already called
        // buildTimelineSegments() before this function runs, so segments are available.
        // Use the same routing logic as MeetingDetailView: segment-first, blob fallback.
        let meetingID = meeting.id
        let segmentDescriptor = FetchDescriptor<TranscriptSegment>(
            predicate: #Predicate { $0.meetingId == meetingID },
            sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.sequenceIndex)]
        )
        let segments = (try? modelContext.fetch(segmentDescriptor)) ?? []
        print("[AutoAnalysis] starting for '\(meeting.title)' elapsed=\(Int(elapsed))s segments=\(segments.count)")

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
        meeting.meetingType          = analysis.meetingType
        meeting.decisions            = analysis.decisions
        meeting.openQuestions        = analysis.openQuestions
        meeting.risks                = analysis.risks
        meeting.dependencies         = analysis.dependencies
        meeting.actionItems          = analysis.actionItems
        meeting.suggestedTaskTitles  = analysis.suggestedTasks
        meeting.commitments          = analysis.commitments.map { CommitmentItem(title: $0) }
        // Always overwrite structuredActionItemsJSON — including with empty arrays.
        // A conditional write left stale JSON from a prior analysis in place.
        if let data = try? JSONEncoder().encode(analysis.structuredActionItems),
           let json = String(data: data, encoding: .utf8) {
            meeting.structuredActionItemsJSON = json
        }
        modelContext.safeSave(context: "auto-analysis")
        // Build and persist knowledge snapshot (includes evidence + hallucination report)
        persistKnowledgeSnapshot(for: meeting, evidence: analysis.evidence)
        print("[AutoAnalysis] complete — summary chars=\(analysis.summary.count) conservative=\(analysis.conservativeSummary.count) decisions=\(analysis.decisions.count) actions=\(analysis.actionItems.count)")
    }

    // MARK: - Knowledge snapshot

    /// Builds a `MeetingKnowledgeSnapshot` from the meeting's current analysis fields
    /// and persists it as JSON.  Called after every successful analysis so folder
    /// intelligence can use compact structured data instead of raw transcripts.
    private func persistKnowledgeSnapshot(for meeting: MeetingItem,
                                           evidence: MeetingAnalysisEvidence? = nil) {
        var snapshot = MeetingKnowledgeSnapshot(from: meeting)
        if let evidence { snapshot.applyEvidence(from: evidence) }
        guard let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }
        meeting.meetingKnowledgeJSON = json
        modelContext.safeSave(context: "meeting knowledge snapshot")
    }

    // MARK: - Pending notification action (background recording start)

    /// Processes a "Start Recording" action that was queued via UserDefaults while
    /// the app was in the background or not running.
    ///
    /// Called from both `onAppear` (cold launch via notification tap) and
    /// `onChange(of: scenePhase)` (background → active transition).
    private func processPendingNotificationAction() {
        guard UserDefaults.standard.bool(
            forKey: MeetingNotificationService.pendingStartRecordingKey
        ) else { return }
        UserDefaults.standard.removeObject(
            forKey: MeetingNotificationService.pendingStartRecordingKey
        )
        Task { @MainActor in
            await startRecordingFromDetectedMeeting()
        }
    }

    @MainActor
    private func startRecordingFromDetectedMeeting() async {
        guard !recordingService.isRecording else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        let meeting = MeetingItem(
            title: "Meeting — \(formatter.string(from: Date()))",
            date: Date()
        )

        modelContext.insert(meeting)
        modelContext.safeSave(context: "meeting")
        activeRecordingMeeting = meeting

        await Task.yield()

        selectedModule = .meetings
        meetingDetector.dismissPrompt()

        await recordingService.startRecording(for: meeting.id)
        await systemAudioService.startCapturing(for: meeting.id)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(OrinColor.accent)
                if !isSidebarCollapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Orin")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(OrinColor.primaryText(colorScheme))
                        Text("Think Less. Do Better.")
                            .font(OrinFont.caption)
                            .foregroundStyle(OrinColor.secondaryText(colorScheme))
                    }
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isSidebarCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isSidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(isSidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar")
            }
            .padding(.horizontal, isSidebarCollapsed ? 14 : 20)
            .padding(.top, 20)

            VStack(spacing: 6) {
                ForEach(SidebarModule.allCases, id: \.self) { module in
                    SidebarItem(
                        module: module,
                        isSelected: selectedModule == module,
                        isCollapsed: isSidebarCollapsed,
                        action: { selectedModule = module }
                    )
                }
            }
            .padding(.horizontal, 14)

            Spacer()
        }
        .background(OrinColor.sidebarBackground(colorScheme))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(OrinColor.border(colorScheme))
                .frame(width: 1)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedModule {
        case .today:
            TodayView()
        case .allTasks:
            AllTasksView()
        case .calendar:
            CalendarView()
        case .meetings:
            MeetingsView()
        case .backlog:
            BacklogView()
        case .vault:
            VaultView()
        case .settings:
            SettingsView()
        }
    }
}

private struct SidebarItem: View {
    @Environment(\.colorScheme) private var colorScheme
    let module: MainContainerView.SidebarModule
    let isSelected: Bool
    let isCollapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(isSelected ? OrinColor.accent : Color.clear)
                    .frame(width: 3, height: 28)
                    .clipShape(Capsule())

                Image(systemName: module.iconName)
                    .frame(width: 22)

                if !isCollapsed {
                    Text(module.title)
                        .font(OrinFont.body.weight(isSelected ? .semibold : .regular))

                    Spacer()
                }
            }
            .foregroundStyle(isSelected ? OrinColor.accent : OrinColor.primaryText(colorScheme))
            .frame(height: 48)
            .padding(.trailing, isCollapsed ? 0 : 12)
            .background(isSelected ? OrinColor.accent.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(module.title)
    }
}
