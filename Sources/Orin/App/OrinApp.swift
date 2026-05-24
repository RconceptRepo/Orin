import OSLog
import SwiftData
import SwiftUI

struct OrinApp: App {
    @AppStorage("orin.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private let modelContainer: ModelContainer
    private let rolloverEngine: RolloverEngine

    init() {
        do {
            let schema = Schema([
                TaskItem.self,
                SubTaskItem.self,
                MeetingItem.self,
                CommitmentItem.self,
                VaultItem.self,
                AISuggestionItem.self,
                DailyBriefItem.self,
                FocusPatternItem.self
            ])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            rolloverEngine = RolloverEngine(container: modelContainer)

            let services = ServiceContainer.shared
            services.register(rolloverEngine, for: RolloverEngine.self)
            services.register(CalendarService(), for: CalendarService.self)
            services.register(VaultService(), for: VaultService.self)
            services.register(RecordingService(), for: RecordingService.self)
            let aiService = AIService(config: AIConfiguration(primaryProvider: .ollama))
            services.register(aiService, for: AIService.self)
            services.register(MeetingIntelligenceService(aiService: aiService), for: MeetingIntelligenceService.self)
            services.register(ReflowEngine(), for: ReflowEngine.self)
            services.register(DailyBriefService(), for: DailyBriefService.self)
            services.register(VoiceCommandService(), for: VoiceCommandService.self)
            services.register(OllamaInstallerService(), for: OllamaInstallerService.self)
            services.register(AIProviderTestService(), for: AIProviderTestService.self)
            services.register(MeetingDetectorService(), for: MeetingDetectorService.self)
            services.register(LoginItemService(), for: LoginItemService.self)
            services.register(WhisperTranscriptionService(), for: WhisperTranscriptionService.self)

            let retentionService = MeetingRetentionService()
            services.register(retentionService, for: MeetingRetentionService.self)

            let assistantService = AssistantService()
            assistantService.configure(with: modelContainer)
            services.register(assistantService, for: AssistantService.self)

            QuickCaptureWindowManager.shared.configure(modelContainer: modelContainer)

            // Prune expired meetings on launch
            let retentionDays = UserDefaults.standard.integer(forKey: "orin.meetings.retentionDays")
            let policy = MeetingRetentionService.RetentionPolicy.from(rawValue: retentionDays == 0
                ? MeetingRetentionService.RetentionPolicy.thirtyDays.rawValue : retentionDays)
            do {
                try retentionService.pruneExpiredMeetings(in: modelContainer.mainContext, policy: policy)
            } catch {
                // Non-fatal on launch — log and continue. ErrorManager is not yet usable here.
                let logger = Logger(subsystem: "com.clavrit.orin", category: "App")
                logger.error("Failed to prune expired meetings: \(error)")
            }
        } catch {
            fatalError("Failed to initialize Orin: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainContainerView()
                .modelContainer(modelContainer)
                .onAppear {
                    rolloverEngine.verifyAndExecuteRollover()
                    ServiceContainer.shared.resolve(AssistantService.self).processPendingIntents()
                    bringWindowToFront()
                }
                .onOpenURL { url in
                    ServiceContainer.shared.resolve(AssistantService.self).handleURL(url)
                }
                .sheet(isPresented: Binding(
                    get: { !hasCompletedOnboarding },
                    set: { if !$0 { hasCompletedOnboarding = true } }
                )) {
                    OnboardingView()
                        .interactiveDismissDisabled()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Quick Capture") {
                    QuickCaptureWindowManager.shared.toggle()
                }
                .keyboardShortcut(" ", modifiers: [.control, .option])
            }
        }

        MenuBarExtra("Orin", systemImage: "bolt.shield") {
            OrinMenuBarView()
        }
        .menuBarExtraStyle(.window)
    }

    private func bringWindowToFront() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
