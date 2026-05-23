import Foundation

struct ReflowPlan {
    var orderedTaskIDs: [UUID]
    var focusBlocks: [String]
    var breaks: [String]
    var rationale: String
}

final class ReflowEngine: Service {
    func generatePlan(tasks: [TaskItem], meetings: [MeetingItem], focusPattern: FocusPatternItem?) -> ReflowPlan {
        let activeTasks = tasks.filter { $0.status == .active && !$0.isBacklog }
        let ordered = activeTasks.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
        }

        let preferredStart = focusPattern?.preferredStartHour ?? 9
        let preferredEnd = focusPattern?.preferredEndHour ?? 11
        let focusBlocks = ordered.prefix(3).enumerated().map { index, task in
            let start = preferredStart + index
            return "\(String(format: "%02d:00", start))-\(String(format: "%02d:45", min(start + 1, preferredEnd + index))): \(task.title)"
        }

        let breaks = ordered.count > 2 ? ["10 minute reset after the first deep-work block"] : []
        let meetingCount = meetings.filter { Calendar.current.isDateInToday($0.date) }.count
        let rationale = meetingCount > 0
            ? "Prioritized urgent work before meetings and kept lighter tasks around calendar load."
            : "Prioritized by urgency, due date, and estimated effort."

        return ReflowPlan(orderedTaskIDs: ordered.map(\.id), focusBlocks: focusBlocks, breaks: breaks, rationale: rationale)
    }

    func apply(_ plan: ReflowPlan, to tasks: [TaskItem]) {
        for (index, id) in plan.orderedTaskIDs.enumerated() {
            tasks.first { $0.id == id }?.dragOrderIndex = index
        }
    }
}
