import Foundation
import OSLog

// MARK: - FolderSummaryService
//
// Generates cross-meeting intelligence for a folder.
//
// Input:  all MeetingItems in a folder (summaries, decisions, action items, transcripts)
// Output: FolderSummaryItem with:
//   - overallSummary      – AI-generated recurring-theme summary
//   - recurringDecisions  – decisions appearing in multiple meetings
//   - recurringActionItems – action items appearing in multiple meetings
//   - recurringTopics     – extracted keyword clusters
//
// The service limits AI input to the 10 most recent meeting summaries to stay
// within typical context windows. Keyword extraction is used as a fallback and
// for recurringTopics (which don't require AI).

final class FolderSummaryService: Service {

    private let log = Logger(subsystem: "com.clavrit.orin", category: "FolderSummary")

    /// Maximum number of meeting summaries to include in the AI prompt.
    private let maxMeetingsForAI = 10

    // MARK: - Public API

    func generate(
        folderName: String,
        folderID: UUID,
        meetings: [MeetingItem],
        aiService: AIService
    ) async -> FolderSummaryItem {
        let item = FolderSummaryItem(folderID: folderID)
        item.meetingCount = meetings.count

        guard !meetings.isEmpty else {
            item.overallSummary = "No meetings in this folder yet."
            return item
        }

        let sorted = meetings.sorted { $0.date > $1.date }

        // Build the AI prompt from the most recent meetings
        let promptMeetings = Array(sorted.prefix(maxMeetingsForAI))
        let prompt = buildPrompt(folderName: folderName, meetings: promptMeetings)

        // Generate overall summary via AI (with fallback)
        let summaryResult = await aiService.generateSummary(for: prompt)
        item.overallSummary = summaryResult.fallbackUsed
            ? buildFallbackSummary(folderName: folderName, meetings: promptMeetings)
            : summaryResult.text

        let minOccurrences = max(2, meetings.count / 3)

        // Recurring decisions / action items from ALL meetings
        item.recurringDecisions   = findRecurring(in: meetings.flatMap(\.decisions),
                                                  minOccurrences: minOccurrences)
        item.recurringActionItems = findRecurring(in: meetings.flatMap(\.actionItems),
                                                  minOccurrences: minOccurrences)

        // NEW: Recurring blockers (from risks + open questions that repeat)
        let allBlockerCandidates  = meetings.flatMap(\.risks) + meetings.flatMap(\.openQuestions)
        item.recurringBlockers    = findRecurring(in: allBlockerCandidates,
                                                  minOccurrences: minOccurrences)

        // NEW: Recurring risks from structured risk fields
        item.recurringRisks       = findRecurring(in: meetings.flatMap(\.risks),
                                                  minOccurrences: minOccurrences)

        // Recurring topics (keyword frequency across all content)
        item.recurringTopics = extractTopics(from: meetings, topN: 8)

        item.generatedAt = Date()
        log.info("folder summary generated folderID=\(folderID) meetings=\(meetings.count) topicsExtracted=\(item.recurringTopics.count)")
        return item
    }

    // MARK: - Prompt Construction

    private func buildPrompt(folderName: String, meetings: [MeetingItem]) -> String {
        var parts = ["MEETING FOLDER: \(folderName) (\(meetings.count) meetings)"]
        parts.append("")
        parts.append("=== MEETING SUMMARIES ===")

        for meeting in meetings {
            let dateStr  = meeting.date.formatted(date: .abbreviated, time: .omitted)
            let typeTag  = meeting.meetingType.isEmpty ? "" : " [\(meeting.meetingType)]"
            parts.append("\(dateStr): \(meeting.title)\(typeTag)")
            if !meeting.summary.isEmpty { parts.append(meeting.summary) }
            if !meeting.decisions.isEmpty {
                parts.append("Decisions: " + meeting.decisions.prefix(3).joined(separator: "; "))
            }
            if !meeting.risks.isEmpty {
                parts.append("Risks: " + meeting.risks.prefix(2).joined(separator: "; "))
            }
            parts.append("")
        }

        if meetings.flatMap(\.decisions).count > 0 {
            parts.append("=== ALL DECISIONS ===")
            for d in meetings.flatMap(\.decisions).prefix(20) { parts.append("• \(d)") }
            parts.append("")
        }

        if meetings.flatMap(\.actionItems).count > 0 {
            parts.append("=== ALL ACTION ITEMS ===")
            for a in meetings.flatMap(\.actionItems).prefix(20) { parts.append("• \(a)") }
            parts.append("")
        }

        parts.append("Based on these \(meetings.count) meetings, write a concise paragraph (3-5 sentences) summarising the recurring themes, ongoing progress, and key patterns across this meeting series.")
        return parts.joined(separator: "\n")
    }

    private func buildFallbackSummary(folderName: String, meetings: [MeetingItem]) -> String {
        let sentences = meetings
            .compactMap { m -> String? in
                let s = m.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            .prefix(3)
        if sentences.isEmpty {
            return "\(folderName) contains \(meetings.count) meetings."
        }
        return sentences.joined(separator: " ")
    }

    // MARK: - Recurring Item Detection

    /// Finds items that appear (verbatim or near-verbatim) in at least `minOccurrences` times.
    private func findRecurring(in items: [String], minOccurrences: Int) -> [String] {
        let normalized = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var freq: [String: (canonical: String, count: Int)] = [:]
        for (orig, norm) in zip(items, normalized) where !norm.isEmpty {
            if let existing = freq[norm] {
                freq[norm] = (existing.canonical, existing.count + 1)
            } else {
                freq[norm] = (orig.trimmingCharacters(in: .whitespacesAndNewlines), 1)
            }
        }
        return freq.values
            .filter { $0.count >= minOccurrences }
            .sorted { $0.count > $1.count }
            .prefix(6)
            .map(\.canonical)
    }

    // MARK: - Topic Extraction

    private func extractTopics(from meetings: [MeetingItem], topN: Int) -> [String] {
        let allText = meetings.flatMap { m -> [String] in
            [m.summary] + m.decisions + m.actionItems
        }.joined(separator: " ")

        var freq: [String: Int] = [:]
        allText
            .lowercased()
            .components(separatedBy: .init(charactersIn: " .,;:!?-_()[]{}\"'"))
            .map    { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count >= 4 && !FolderSummaryService.topicStopWords.contains($0) }
            .forEach { freq[$0, default: 0] += 1 }

        return freq
            .filter { $0.value >= 2 }               // must appear in ≥ 2 places
            .sorted { $0.value > $1.value }
            .prefix(topN)
            .map { $0.key.capitalized }
    }

    private static let topicStopWords: Set<String> = [
        "that", "this", "with", "have", "from", "they", "will", "been",
        "were", "each", "more", "also", "when", "then", "than", "into",
        "need", "what", "said", "some", "about", "which", "would", "could",
        "should", "their", "there", "these", "those", "other", "after"
    ]
}
