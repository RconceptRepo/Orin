import AppIntents
import Foundation

struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Task"
    static var description = IntentDescription("Create a task in Orin.")

    @Parameter(title: "Task")
    var task: String

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(task, forKey: "orin.pendingIntentTask")
        return .result()
    }
}

struct ReflowDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Reflow My Day"
    static var description = IntentDescription("Ask Orin to reflow today's work.")

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "orin.pendingIntentReflow")
        return .result()
    }
}

struct SummarizeTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "Summarize Today"
    static var description = IntentDescription("Open Orin's daily summary.")

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "orin.pendingIntentSummary")
        return .result()
    }
}

struct OrinShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(), phrases: ["Add a task in \(.applicationName)"], shortTitle: "Add Task", systemImageName: "plus.circle")
        AppShortcut(intent: ReflowDayIntent(), phrases: ["Reflow my day in \(.applicationName)"], shortTitle: "Reflow Day", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: SummarizeTodayIntent(), phrases: ["Summarize today in \(.applicationName)"], shortTitle: "Summarize Today", systemImageName: "sun.max")
    }
}
