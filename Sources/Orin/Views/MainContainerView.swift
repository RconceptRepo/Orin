import SwiftData
import SwiftUI

struct MainContainerView: View {
    @AppStorage("orin.theme.mode") private var themeModeRawValue = OrinThemeMode.system.rawValue
    @AppStorage("orin.calendar.backgroundSync") private var calendarBackgroundSync = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @State private var selectedModule: SidebarModule = .today
    @State private var recordingService = ServiceContainer.shared.resolve(RecordingService.self)
    @State private var meetingDetector = ServiceContainer.shared.resolve(MeetingDetectorService.self)
    @State private var calendarService = ServiceContainer.shared.resolve(CalendarService.self)
    @State private var activeRecordingMeeting: MeetingItem?

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
                        .frame(width: max(280, proxy.size.width * 0.3))

                    detail
                        .frame(width: proxy.size.width * 0.7)
                        .background(OrinColor.backgroundPrimary(colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .trailing, spacing: 14) {
                    if meetingDetector.shouldShowRecordingPrompt, let appName = meetingDetector.detectedMeetingApp {
                        MeetingRecordingPromptView(
                            appName: appName,
                            onStart: {
                                // CRASH-DIAG: This closure is the button action. It runs in
                                // SwiftUI's event-handling context (NOT a Swift task yet).
                                // The Task {} below creates a proper Swift Concurrency task.
                                CrashDiag.trace("onStart closure entered — creating Task. inTask=\(CrashDiag.isInSwiftTask)")
                                Task { @MainActor in
                                    // CRASH-DIAG: T+0 — we are now inside Task {@MainActor in}.
                                    // inTask MUST be true here; if false the subsequent @Observable
                                    // mutations will reach @Query.update() without a task context.
                                    CrashDiag.trace("onStart TASK BEGIN inTask=\(CrashDiag.isInSwiftTask) ctx=\(CrashDiag.addr(modelContext))")

                                    let formatter = DateFormatter()
                                    formatter.dateStyle = .short
                                    formatter.timeStyle = .short

                                    // CRASH-DIAG: T+1 — MeetingItem created (before context assign).
                                    // MeetingItem.init will also log its address.
                                    let meeting = MeetingItem(
                                        title: "Meeting — \(formatter.string(from: Date()))",
                                        date: Date()
                                    )
                                    CrashDiag.trace("onStart MeetingItem created id=\(meeting.id) addr=\(CrashDiag.addr(meeting))")

                                    // CRASH-DIAG: T+2 — insert. No context yet; this assigns one.
                                    modelContext.insert(meeting)
                                    CrashDiag.trace("onStart modelContext.insert done id=\(meeting.id) inTask=\(CrashDiag.isInSwiftTask)")

                                    // CRASH-DIAG: T+3 — THE CRITICAL SAVE.
                                    // safeSave → save() → SwiftData fires ModelContext change
                                    // notification synchronously.  TodayView's
                                    // @Query(sort: \MeetingItem.date) is currently live (the
                                    // user is on the Today module).  Its @Query.update() fires
                                    // from inside this save call.
                                    //
                                    // If isInSwiftTask is TRUE here AND the crash still occurs,
                                    // the bug is NOT about task context but about the @Query
                                    // firing on a TodayView DynamicPropertyStorage that is freed
                                    // by "selectedModule = .meetings" in the same render cycle.
                                    CrashDiag.trace("onStart → safeSave BEGIN (selectedModule still=\(selectedModule))")
                                    modelContext.safeSave(context: "meeting")
                                    CrashDiag.trace("onStart → safeSave END  (app still running — no crash yet)")

                                    // CRASH-DIAG: T+4
                                    activeRecordingMeeting = meeting
                                    CrashDiag.trace("onStart activeRecordingMeeting set id=\(meeting.id) addr=\(CrashDiag.addr(meeting))")

                                    // CRASH-DIAG: T+5 — THIS QUEUES TodayView TEARDOWN.
                                    // After this line, SwiftUI will remove TodayView (which owns
                                    // the @Query that just received a save notification) from the
                                    // hierarchy.  The teardown and the pending @Query.update()
                                    // race at the next yield point (the "await" below).
                                    selectedModule = .meetings
                                    CrashDiag.trace("onStart selectedModule = .meetings (TodayView teardown queued)")

                                    // CRASH-DIAG: T+6 — FIRST GENUINE SUSPENSION POINT.
                                    // The main actor yields here.  SwiftUI runs pending renders:
                                    //   (a) selectedModule change → tears down TodayView,
                                    //       frees TodayView's DynamicPropertyStorage
                                    //   (b) pending @Query notification for TodayView's
                                    //       @Query(MeetingItem) fires → EmbeddedDynamicPropertyBox
                                    //       .update() → use-after-free → CRASH at 0x1e
                                    //
                                    // If the app crashes BEFORE printing the line below, the
                                    // crash happens at this await boundary.
                                    CrashDiag.trace("onStart → await startRecording BEGIN meetingID=\(meeting.id)")
                                    await recordingService.startRecording(for: meeting.id)
                                    CrashDiag.trace("onStart → await startRecording END phase=\(recordingService.isRecording)")

                                    // CRASH-DIAG: T+7
                                    meetingDetector.dismissPrompt()
                                    CrashDiag.trace("onStart TASK END dismissPrompt called")
                                }
                            },
                            onDismiss: {
                                CrashDiag.trace("onDismiss closure entered")
                                meetingDetector.dismissPrompt()
                            }
                        )
                    }

                    if recordingService.isRecording || recordingService.errorMessage != nil {
                        RecordingWidgetView(recordingService: recordingService) {
                            recordingService.stopRecording()
                        }
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
            CrashDiag.trace("MainContainerView.onAppear selectedModule=\(selectedModule)")
            meetingDetector.startMonitoring()
            calendarService.refreshAuthorizationStatus()
            if calendarBackgroundSync {
                calendarService.startBackgroundSync()
            }
        }
        // CRASH-DIAG: Track every module navigation. The key transition is
        // .today → .meetings triggered from onStart. If this fires BEFORE
        // "safeSave END" is logged, the ordering hypothesis is wrong.
        .onChange(of: selectedModule) { old, new in
            CrashDiag.trace("MainContainerView selectedModule changed: \(old) → \(new) inTask=\(CrashDiag.isInSwiftTask)")
        }
        // CRASH-DIAG: Track activeRecordingMeeting identity. If its address
        // differs from the @Query result that MeetingDetailView receives, we have
        // two distinct Swift objects for the same persistent record — which means
        // MainContainerView and MeetingDetailView are double-writing on stop.
        .onChange(of: activeRecordingMeeting?.id) { old, new in
            let addr = activeRecordingMeeting.map { CrashDiag.addr($0) } ?? "nil"
            CrashDiag.trace("MainContainerView activeRecordingMeeting.id: \(String(describing: old)) → \(String(describing: new)) addr=\(addr)")
        }
        // CRASH-DIAG: Track prompt lifecycle.
        .onChange(of: meetingDetector.shouldShowRecordingPrompt) { _, shown in
            CrashDiag.trace("MainContainerView shouldShowRecordingPrompt=\(shown) app=\(meetingDetector.detectedMeetingApp ?? "nil")")
        }
        // CRASH-DIAG: Track recording phase transitions. isRecording goes TRUE
        // during startRecording (inside the await), and FALSE when stopRecording
        // fires. Any crash between the TRUE and FALSE events pinpoints the window.
        .onChange(of: recordingService.isRecording) { _, isNow in
            CrashDiag.trace("MainContainerView recordingService.isRecording=\(isNow) activeMeetingID=\(String(describing: recordingService.activeMeetingID)) inTask=\(CrashDiag.isInSwiftTask)")
            guard !isNow, let meeting = activeRecordingMeeting else { return }
            // CRASH-DIAG: recording stopped — about to mutate MeetingItem and save.
            // This is a SECOND write path (MeetingDetailView has its own matching handler).
            // Both will fire on stop, both mutating different Swift object references
            // to the same persistent record, and both calling safeSave.
            CrashDiag.trace("MainContainerView recording stopped — writing to meeting id=\(meeting.id) addr=\(CrashDiag.addr(meeting))")
            meeting.transcript = recordingService.transcript
            meeting.durationSeconds = TimeInterval(recordingService.elapsedSeconds)
            if let url = recordingService.recordingURL {
                meeting.audioFilePath = url.path
            }
            modelContext.safeSave(context: "meeting recording")
            activeRecordingMeeting = nil
            CrashDiag.trace("MainContainerView activeRecordingMeeting cleared")
        }
        .onChange(of: calendarBackgroundSync) { _, enabled in
            if enabled {
                calendarService.startBackgroundSync()
            } else {
                calendarService.stopBackgroundSync()
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(OrinColor.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orin")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(OrinColor.primaryText(colorScheme))
                    Text("Think Less. Do Better.")
                        .font(OrinFont.caption)
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            VStack(spacing: 6) {
                ForEach(SidebarModule.allCases, id: \.self) { module in
                    SidebarItem(
                        module: module,
                        isSelected: selectedModule == module,
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

                Text(module.title)
                    .font(OrinFont.body.weight(isSelected ? .semibold : .regular))

                Spacer()
            }
            .foregroundStyle(isSelected ? OrinColor.accent : OrinColor.primaryText(colorScheme))
            .frame(height: 48)
            .padding(.trailing, 12)
            .background(isSelected ? OrinColor.accent.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
