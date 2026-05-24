import AppIntents
import Foundation
import SwiftData

// MARK: - What's Left Today

struct WhatsLeftTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Left Today"
    static var description = IntentDescription("Get a summary of today's active tasks.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = (try? await buildSummary()) ?? "Couldn't load tasks right now."
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }

    private func buildSummary() async throws -> String {
        let schema = Schema([
            TaskItem.self, SubTaskItem.self, MeetingItem.self, CommitmentItem.self,
            VaultItem.self, AISuggestionItem.self, DailyBriefItem.self, FocusPatternItem.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container = try ModelContainer(for: schema, configurations: [config])
        return try await MainActor.run {
            try AssistantService.buildTodaySummary(from: container.mainContext)
        }
    }
}

// MARK: - Reflow Day

struct ReflowDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Reflow My Day"
    static var description = IntentDescription("Ask Orin to replan today's work schedule.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults.standard.set(true, forKey: "orin.pendingIntentReflow")
        return .result(dialog: "Opening Orin to reflow your day.")
    }
}

// MARK: - Add Task

struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Task"
    static var description = IntentDescription("Create a task in Orin.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task")
    var task: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let created = await writeTask(task)
        if created {
            return .result(dialog: IntentDialog(stringLiteral: "Added '\(task)' to Orin."))
        }
        UserDefaults.standard.set(task, forKey: "orin.pendingIntentTask")
        return .result(dialog: IntentDialog(stringLiteral: "'\(task)' queued — open Orin to confirm."))
    }

    private func writeTask(_ text: String) async -> Bool {
        do {
            let schema = Schema([
                TaskItem.self, SubTaskItem.self, MeetingItem.self, CommitmentItem.self,
                VaultItem.self, AISuggestionItem.self, DailyBriefItem.self, FocusPatternItem.self
            ])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema, configurations: [config])
            return try await MainActor.run {
                let context = container.mainContext
                if let parsed = QuickCaptureParser.parse(text) {
                    context.insert(TaskItem(title: parsed.title, priority: parsed.priority, dueDate: parsed.dueDate))
                } else {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return false }
                    context.insert(TaskItem(title: trimmed))
                }
                try context.save()
                return true
            }
        } catch {
            return false
        }
    }
}

// MARK: - App Shortcuts (Siri phrases)

struct OrinShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsLeftTodayIntent(),
            phrases: [
                "What's left today in \(.applicationName)",
                "What do I have left today in \(.applicationName)",
                "Show my tasks in \(.applicationName)"
            ],
            shortTitle: "What's Left Today",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: ReflowDayIntent(),
            phrases: [
                "Reflow my day in \(.applicationName)",
                "Replan my day in \(.applicationName)"
            ],
            shortTitle: "Reflow Day",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Add task in \(.applicationName)",
                "Create task in \(.applicationName)"
            ],
            shortTitle: "Add Task",
            systemImageName: "plus.circle"
        )
    }
}
