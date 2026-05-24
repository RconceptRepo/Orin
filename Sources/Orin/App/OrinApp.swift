import SwiftData
import SwiftUI

struct OrinApp: App {
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
            services.register(MeetingDetectorService(), for: MeetingDetectorService.self)
            services.register(LoginItemService(), for: LoginItemService.self)

            QuickCaptureWindowManager.shared.configure(modelContainer: modelContainer)
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
                }
        }
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
}
