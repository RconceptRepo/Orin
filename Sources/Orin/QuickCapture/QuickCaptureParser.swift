import Foundation

struct ParsedTaskInput {
    var title: String
    var priority: TaskPriority
    var dueDate: Date?
}

enum QuickCaptureParser {
    static func parse(_ input: String, calendar: Calendar = .current) -> ParsedTaskInput? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var words = trimmed.split(separator: " ").map(String.init)
        var priority: TaskPriority = .p3Low
        var dueDate: Date?

        if let priorityIndex = words.lastIndex(where: { $0.uppercased().range(of: #"^P[0-3]$"#, options: .regularExpression) != nil }) {
            let token = words.remove(at: priorityIndex).uppercased()
            priority = switch token {
            case "P0": .p0Critical
            case "P1": .p1High
            case "P2": .p2Medium
            default: .p3Low
            }
        }

        if let tomorrowIndex = words.lastIndex(where: { $0.lowercased() == "tomorrow" }) {
            words.remove(at: tomorrowIndex)
            dueDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        } else if let todayIndex = words.lastIndex(where: { $0.lowercased() == "today" }) {
            words.remove(at: todayIndex)
            dueDate = calendar.startOfDay(for: Date())
        }

        let title = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return ParsedTaskInput(title: title, priority: priority, dueDate: dueDate)
    }
}
