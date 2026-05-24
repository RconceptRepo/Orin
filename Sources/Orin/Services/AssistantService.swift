import Foundation
import SwiftData

/// Routes voice/intent commands and URL deep links into live services.
/// App Intents call static helpers directly; URL scheme events set UserDefaults
/// flags that OrinApp processes on the next foreground pass.
@Observable
final class AssistantService: Service {

    private weak var modelContainer: ModelContainer?

    func configure(with container: ModelContainer) {
        modelContainer = container
    }

    // MARK: - URL Scheme Handling

    /// Returns true if the URL was handled.
    @MainActor
    @discardableResult
    func handleURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "orin" else { return false }
        switch url.host?.lowercased() {
        case "whatsLeftToday".lowercased():
            UserDefaults.standard.set(true, forKey: "orin.pendingIntentSummary")
            return true
        case "reflow":
            UserDefaults.standard.set(true, forKey: "orin.pendingIntentReflow")
            return true
        case "addTask".lowercased():
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let title = components?.queryItems?.first(where: { $0.name == "title" })?.value ?? ""
            let due   = components?.queryItems?.first(where: { $0.name == "due"   })?.value
            if !title.isEmpty {
                var combined = title
                if let due { combined += " \(due)" }
                UserDefaults.standard.set(combined, forKey: "orin.pendingIntentTask")
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Pending Intent Processing (called on foreground / onAppear)

    @MainActor
    func processPendingIntents() {
        if UserDefaults.standard.bool(forKey: "orin.pendingIntentReflow") {
            UserDefaults.standard.removeObject(forKey: "orin.pendingIntentReflow")
            // Reflow requires the full UI context — set a notification for TodayView to pick up.
            NotificationCenter.default.post(name: .orinReflowRequested, object: nil)
        }

        if UserDefaults.standard.bool(forKey: "orin.pendingIntentSummary") {
            UserDefaults.standard.removeObject(forKey: "orin.pendingIntentSummary")
            NotificationCenter.default.post(name: .orinSummaryRequested, object: nil)
        }

        if let text = UserDefaults.standard.string(forKey: "orin.pendingIntentTask"), !text.isEmpty {
            UserDefaults.standard.removeObject(forKey: "orin.pendingIntentTask")
            createTask(from: text)
        }
    }

    @MainActor
    private func createTask(from text: String) {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        let title: String
        let priority: TaskPriority
        let dueDate: Date?

        if let parsed = QuickCaptureParser.parse(text) {
            title    = parsed.title
            priority = parsed.priority
            dueDate  = parsed.dueDate
        } else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            title    = trimmed
            priority = .p3Low
            dueDate  = nil
        }

        let task = TaskItem(title: title, priority: priority, dueDate: dueDate)
        context.insert(task)
        context.safeSave(context: "task from voice command")
    }

    // MARK: - Summary Builder (called from App Intents, takes an explicit context)

    static func buildTodaySummary(from context: ModelContext) throws -> String {
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { !$0.isBacklog && $0.statusValue == "active" }
        )
        let tasks = try context.fetch(descriptor)
        guard !tasks.isEmpty else { return "No active tasks for today. All clear!" }
        let top = tasks.sorted { $0.priorityValue < $1.priorityValue }.prefix(5)
        return "Here's what's left today:\n" + top.map { "• \($0.title)" }.joined(separator: "\n")
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let orinReflowRequested  = Notification.Name("com.rconcept.orin.reflowRequested")
    static let orinSummaryRequested = Notification.Name("com.rconcept.orin.summaryRequested")
}
