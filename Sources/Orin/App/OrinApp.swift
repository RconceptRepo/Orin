import OSLog
import SwiftData
import SwiftUI

struct OrinApp: App {
    @AppStorage("orin.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private let modelContainer: ModelContainer
    private let rolloverEngine: RolloverEngine

    private static let appLogger = Logger(subsystem: "com.clavrit.orin", category: "App")

    // Debug-only: state for the Developer → Reset Application State sheet.
    // Wrapped in #if DEBUG so the property and all its dependencies are
    // completely absent from Release builds.
#if DEBUG
    @State private var showingDebugReset = false
#endif

    init() {
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

        // Build a container with automatic migration-failure recovery.
        // If the on-disk store has an incompatible schema (e.g. a new non-optional
        // attribute was added without a migration plan), SwiftData throws error 1.
        // We delete the store and recreate it rather than crashing.
        modelContainer = Self.makeContainer(schema: schema)
        rolloverEngine = RolloverEngine(container: modelContainer)

        let services = ServiceContainer.shared
        services.register(rolloverEngine, for: RolloverEngine.self)
        let calendarService = CalendarService()
        services.register(calendarService, for: CalendarService.self)
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
        services.register(MeetingDetectorService(calendarService: calendarService), for: MeetingDetectorService.self)
        services.register(LoginItemService(), for: LoginItemService.self)
        services.register(WhisperTranscriptionService(), for: WhisperTranscriptionService.self)
        services.register(SystemAudioCaptureService(), for: SystemAudioCaptureService.self)
        services.register(TranscriptStore(), for: TranscriptStore.self)

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
            Self.appLogger.error("Failed to prune expired meetings: \(error)")
        }
    }

    // MARK: - Container bootstrap

    /// Creates the ModelContainer, recovering automatically if the store is incompatible.
    ///
    /// Recovery order:
    ///   1. Normal open (existing store is compatible — fast path)
    ///   2. Delete store + retry (migration failure, e.g. new non-optional column)
    ///   3. In-memory fallback (disk is unwritable — app still launches, data is transient)
    private static func makeContainer(schema: Schema) -> ModelContainer {
        // Attempt 1 — normal path
        if let container = try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        ) { return container }

        // Attempt 2 — migration failed; locate and delete the incompatible store
        appLogger.warning("SwiftData store open failed — attempting store reset.")
        deleteStoreFiles(for: schema)

        if let container = try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        ) {
            appLogger.warning("Store reset succeeded. All local data has been cleared.")
            return container
        }

        // Attempt 3 — disk issue; run in-memory so the app still launches
        appLogger.error("All persistent-store attempts failed — falling back to in-memory store.")
        // swiftlint:disable:next force_try
        return try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private static func deleteStoreFiles(for schema: Schema) {
        // SwiftData default URL mirrors what ModelConfiguration resolves to.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let storeURL = config.url
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            if fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) }
                catch { appLogger.error("Could not remove store file \(url.lastPathComponent): \(error)") }
            }
        }
        appLogger.warning("Deleted store at \(storeURL.path).")
    }

    var body: some Scene {
        WindowGroup {
            MainContainerView()
                .modelContainer(modelContainer)
                .onAppear {
                    rolloverEngine.verifyAndExecuteRollover()
                    ServiceContainer.shared.resolve(AssistantService.self).processPendingIntents()
                    bringWindowToFront()

                    // Orphan recovery: if the previous session crashed or was force-quit,
                    // restore the most-recent checkpoint text to the meeting model.
                    ServiceContainer.shared.resolve(TranscriptStore.self)
                        .recoverOrphan(in: modelContainer.mainContext)
                }
                // Final checkpoint on clean quit — captures any transcript not yet persisted
                // by the 3-second timer. Runs synchronously on the main actor before the
                // process exits (NSApplication.willTerminateNotification fires on main thread).
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                ) { _ in
                    ServiceContainer.shared.resolve(TranscriptStore.self).checkpoint()
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
#if DEBUG
                // Debug reset sheet — only present in DEBUG builds.
                // Posted by the Developer → Reset Application State menu item.
                .onReceive(
                    NotificationCenter.default.publisher(for: .debugResetRequested)
                ) { _ in
                    showingDebugReset = true
                }
                .sheet(isPresented: $showingDebugReset) {
                    DebugResetView()
                }
#endif
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
#if DEBUG
            // Developer menu — compiled only in DEBUG; absent from Release.
            CommandMenu("Developer") {
                Button("Reset Application State…") {
                    NotificationCenter.default.post(
                        name: .debugResetRequested,
                        object: nil
                    )
                }
                .keyboardShortcut("R", modifiers: [.command, .shift, .option])
                .help("Clear all local data and reproduce the first-launch experience. Debug only.")
            }
#endif
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
