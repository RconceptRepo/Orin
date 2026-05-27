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
                                Task { @MainActor in
                                    let formatter = DateFormatter()
                                    formatter.dateStyle = .short
                                    formatter.timeStyle = .short

                                    let meeting = MeetingItem(
                                        title: "Meeting — \(formatter.string(from: Date()))",
                                        date: Date()
                                    )

                                    modelContext.insert(meeting)

                                    // Save first so SwiftData can fire any pending @Query
                                    // notifications while TodayView is still fully alive.
                                    modelContext.safeSave(context: "meeting")

                                    activeRecordingMeeting = meeting

                                    // Yield before navigating away. This gives SwiftUI one
                                    // pass to process the @Query update for TodayView while
                                    // TodayView is still in the hierarchy — guaranteeing the
                                    // EmbeddedDynamicPropertyBox.update() completes before the
                                    // view is torn down, which prevents the EXC_BAD_ACCESS 0x1e
                                    // use-after-free on the freed @Query storage.
                                    await Task.yield()

                                    selectedModule = .meetings
                                    meetingDetector.dismissPrompt()

                                    await recordingService.startRecording(for: meeting.id)
                                }
                            },
                            onDismiss: {
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
            meetingDetector.startMonitoring()
            calendarService.refreshAuthorizationStatus()
            if calendarBackgroundSync {
                calendarService.startBackgroundSync()
            }
        }
        .onChange(of: recordingService.isRecording) { _, isNow in
            guard !isNow, let meeting = activeRecordingMeeting else { return }
            meeting.transcript = recordingService.transcript
            meeting.durationSeconds = TimeInterval(recordingService.elapsedSeconds)
            if let url = recordingService.recordingURL {
                meeting.audioFilePath = url.path
            }
            modelContext.safeSave(context: "meeting recording")
            activeRecordingMeeting = nil
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
