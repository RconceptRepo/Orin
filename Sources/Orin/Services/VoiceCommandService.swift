import Foundation

enum VoiceCommandResult {
    case createTask(ParsedTaskInput)
    case createBacklog(title: String)
    case reflow
    case summarizeToday
    case unsupported(String)
}

final class VoiceCommandService: Service {
    func parse(_ input: String) -> VoiceCommandResult {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()

        if lower.contains("reflow") {
            return .reflow
        }
        if lower.contains("summarize today") || lower.contains("summary today") {
            return .summarizeToday
        }
        if lower.hasPrefix("add backlog") {
            let title = normalized.replacingOccurrences(of: #"(?i)^add backlog( item)?"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? .unsupported(input) : .createBacklog(title: title)
        }
        if lower.hasPrefix("add task") {
            let title = normalized.replacingOccurrences(of: #"(?i)^add task"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = QuickCaptureParser.parse(title) {
                return .createTask(parsed)
            }
        }
        if let parsed = QuickCaptureParser.parse(normalized) {
            return .createTask(parsed)
        }
        return .unsupported(input)
    }
}
