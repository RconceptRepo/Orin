import Foundation

struct MeetingAnalysis {
    var summary: String
    var decisions: [String]
    var commitments: [String]
    var actionItems: [String]
    var suggestedTasks: [String]
}

final class MeetingIntelligenceService: Service {
    private let aiService: AIService

    init(aiService: AIService) {
        self.aiService = aiService
    }

    // MARK: - Segments-based analysis (preferred when timeline is available)

    /// Analyzes a meeting using its conversation timeline.
    ///
    /// Formats segments into a conversation-style transcript string before
    /// calling the string-based `analyze(title:transcript:)`.  The formatted
    /// string includes speaker labels and time offsets, which may improve AI
    /// summary quality vs. the flat "Me: … Participant: …" format.
    ///
    /// Falls back to `analyze(title:transcript:)` with the raw `fallbackTranscript`
    /// when no segments are provided.
    func analyze(
        title: String,
        segments: [TranscriptSegment],
        meetingStart: Date? = nil,
        fallbackTranscript: String = ""
    ) async -> MeetingAnalysis {
        guard !segments.isEmpty else {
            return await analyze(title: title, transcript: fallbackTranscript)
        }
        let timelineText = ConversationTimelineBuilder.formatted(segments, meetingStart: meetingStart)
        return await analyze(title: title, transcript: timelineText)
    }

    // MARK: - String-based analysis (legacy + fallback)

    func analyze(title: String, transcript: String) async -> MeetingAnalysis {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return MeetingAnalysis(summary: "", decisions: [], commitments: [], actionItems: [], suggestedTasks: [])
        }

        let summaryResult = await aiService.generateSummary(for: trimmedTranscript)
        let summary = summaryResult.fallbackUsed ? fallbackSummary(for: trimmedTranscript) : summaryResult.text
        let decisions = extractLines(from: trimmedTranscript, matching: ["decided", "decision", "agreed", "approved"])
        let commitments = extractLines(from: trimmedTranscript, matching: ["i will", "i'll", "we will", "follow up", "send", "prepare"])
        let actionItems = extractLines(from: trimmedTranscript, matching: ["action", "todo", "to do", "next step", "follow up", "owner"])
        let suggestedTasks = buildSuggestedTasks(title: title, commitments: commitments, actionItems: actionItems)

        return MeetingAnalysis(
            summary: summary,
            decisions: decisions,
            commitments: commitments,
            actionItems: actionItems,
            suggestedTasks: suggestedTasks
        )
    }

    private func fallbackSummary(for transcript: String) -> String {
        let sentences = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return sentences.prefix(3).joined(separator: ". ") + (sentences.isEmpty ? "" : ".")
    }

    private func extractLines(from transcript: String, matching keywords: [String]) -> [String] {
        let candidates = transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let matches = candidates.filter { line in
            let lowercased = line.lowercased()
            return keywords.contains { lowercased.contains($0) }
        }

        return Array(matches.prefix(8))
    }

    private func buildSuggestedTasks(title: String, commitments: [String], actionItems: [String]) -> [String] {
        let rawItems = commitments + actionItems
        let cleaned = rawItems.map { item in
            item
                .replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(Action|TODO|To do|Next step):\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }

        if cleaned.isEmpty {
            return ["Review follow-ups from \(title)"]
        }

        return Array(NSOrderedSet(array: cleaned).array.compactMap { $0 as? String }.prefix(6))
    }
}
