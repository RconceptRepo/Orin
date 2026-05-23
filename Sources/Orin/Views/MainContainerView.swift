import SwiftUI

struct MainContainerView: View {
    @AppStorage("orin.theme.mode") private var themeModeRawValue = OrinThemeMode.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedModule: SidebarModule = .today
    @State private var recordingService = ServiceContainer.shared.resolve(RecordingService.self)
    @State private var meetingDetector = ServiceContainer.shared.resolve(MeetingDetectorService.self)

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
                                recordingService.startRecording()
                                meetingDetector.dismissPrompt()
                            },
                            onDismiss: { meetingDetector.dismissPrompt() }
                        )
                    }

                    if recordingService.isRecording {
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
        .onAppear {
            meetingDetector.startMonitoring()
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
