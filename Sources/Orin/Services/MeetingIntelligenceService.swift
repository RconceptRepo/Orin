import Foundation
import OSLog

// MARK: - MeetingAnalysis

struct MeetingAnalysis {
    var summary: String
    var meetingType: String
    var decisions: [String]
    var openQuestions: [String]
    var risks: [String]
    var dependencies: [String]
    var commitments: [String]
    var actionItems: [String]                       // flat strings (backward compat)
    var structuredActionItems: [ActionItemRecord]   // structured (owner/task/priority/due)
    var suggestedTasks: [String]
}

// MARK: - MeetingIntelligenceService

/// Context-aware meeting analysis using a single comprehensive AI prompt.
///
/// # Pipeline
///
/// 1. **Type detection** — keyword-based, synchronous, no AI required
/// 2. **Comprehensive prompt** — single AI call returns all structured sections
/// 3. **Response parsing** — extracts summary, action items, decisions, questions, risks, dependencies
/// 4. **Keyword fallback** — used if AI fails or response doesn't parse cleanly
///
/// # Output sections
///
/// ```
/// ## SUMMARY       → MeetingAnalysis.summary
/// ## ACTION ITEMS  → .actionItems (flat) + .structuredActionItems (owner/priority/due)
/// ## DECISIONS     → .decisions
/// ## OPEN QUESTIONS → .openQuestions
/// ## RISKS         → .risks
/// ## DEPENDENCIES  → .dependencies
/// ## COMMITMENTS   → .commitments
/// ```

final class MeetingIntelligenceService: Service {

    private let aiService: AIService
    private let log = Logger(subsystem: "com.clavrit.orin", category: "MeetingIntelligence")

    init(aiService: AIService) {
        self.aiService = aiService
    }

    // MARK: - Segments-based analysis (preferred)

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

    // MARK: - String-based analysis

    func analyze(title: String, transcript: String) async -> MeetingAnalysis {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyAnalysis() }

        // Step 1: Detect meeting type (local — no AI)
        let meetingType = MeetingIntelligenceService.detectMeetingType(title: title, transcript: trimmed)

        // Route: long transcripts → chunked hierarchical analysis
        if trimmed.count > TranscriptChunker.singleCallThreshold {
            log.info("long transcript chars=\(trimmed.count) — using chunked analysis")
            return await analyzeChunked(title: title, transcript: trimmed, meetingType: meetingType)
        }

        return await analyzeSingleCall(title: title, transcript: trimmed, meetingType: meetingType)
    }

    // MARK: - Chunked Hierarchical Analysis (Tasks 2+3)
    //
    // For transcripts longer than TranscriptChunker.singleCallThreshold:
    //   1. Split into 5000-char overlapping chunks
    //   2. Extract structured data from each chunk (sequential AI calls)
    //   3. Merge + deduplicate all extracted data
    //   4. Synthesize executive summary from key points

    private func analyzeChunked(
        title: String,
        transcript: String,
        meetingType: String
    ) async -> MeetingAnalysis {
        let chunks = TranscriptChunker.chunks(of: transcript)
        log.info("chunked analysis: \(chunks.count) chunks for title='\(title)'")

        // Phase 1: Extract from each chunk
        var chunkAnalyses: [ChunkAnalysis] = []
        for (i, chunk) in chunks.enumerated() {
            let ca = await TranscriptChunker.analyzeChunk(
                chunk, index: i, totalChunks: chunks.count,
                meetingType: meetingType, aiService: aiService
            )
            chunkAnalyses.append(ca)
        }

        // Phase 2: Merge and deduplicate
        let allDecisions      = TranscriptChunker.deduplicateStrings(chunkAnalyses.flatMap(\.decisions))
        let allOpenQuestions  = TranscriptChunker.deduplicateStrings(chunkAnalyses.flatMap(\.openQuestions))
        let allRisks          = TranscriptChunker.deduplicateStrings(chunkAnalyses.flatMap(\.risks))
        let allDependencies   = TranscriptChunker.deduplicateStrings(chunkAnalyses.flatMap(\.dependencies))
        let allCommitments    = TranscriptChunker.deduplicateStrings(chunkAnalyses.flatMap(\.commitments))
        let allStructured     = TranscriptChunker.deduplicateActionItems(chunkAnalyses.flatMap(\.structuredActionItems))
        let allActionItems    = allStructured.isEmpty
            ? TranscriptChunker.deduplicateStrings(chunkAnalyses.flatMap(\.actionItems))
            : allStructured.map { "[\($0.owner)] \($0.task)" }

        // Phase 3: Synthesize executive summary
        let summary = await TranscriptChunker.synthesize(
            chunks: chunkAnalyses, title: title, meetingType: meetingType, aiService: aiService
        )

        let suggestedTasks = buildSuggestedTasks(
            title: title, commitments: allCommitments,
            actionItems: allActionItems, structuredItems: allStructured
        )

        log.info("chunked analysis complete: summary=\(summary.count)chars decisions=\(allDecisions.count) actions=\(allStructured.count) risks=\(allRisks.count)")

        return MeetingAnalysis(
            summary:               summary,
            meetingType:           meetingType,
            decisions:             allDecisions,
            openQuestions:         allOpenQuestions,
            risks:                 allRisks,
            dependencies:          allDependencies,
            commitments:           allCommitments,
            actionItems:           allActionItems,
            structuredActionItems: allStructured,
            suggestedTasks:        suggestedTasks
        )
    }

    // MARK: - Single-Call Analysis (transcripts ≤ singleCallThreshold)

    private func analyzeSingleCall(
        title: String,
        transcript: String,
        meetingType: String
    ) async -> MeetingAnalysis {
        // Step 1: Build comprehensive structured prompt
        let prompt = buildComprehensivePrompt(title: title, transcript: transcript, meetingType: meetingType)

        // Step 2: Single AI call
        let result = await aiService.generate(prompt: prompt, maxTokens: 1500)

        if result.fallbackUsed || result.text.isEmpty {
            log.warning("AI unavailable — using keyword fallback")
            return keywordFallback(title: title, transcript: transcript, meetingType: meetingType)
        }

        // Step 3: Parse structured response
        let parsed = parseComprehensiveResponse(result.text)

        // If parsing produced almost nothing, run keyword fallback for missing sections
        let decisions     = parsed.decisions.isEmpty
            ? extractCleanLines(from: transcript, matching: ["decided", "decision", "agreed", "approved", "will proceed", "confirmed"])
            : parsed.decisions
        let commitments   = parsed.commitments.isEmpty
            ? extractCleanLines(from: transcript, matching: ["i will", "i'll", "we will", "will send", "will prepare", "will schedule"])
            : parsed.commitments
        let actionItems   = parsed.structuredActionItems.isEmpty
            ? extractCleanLines(from: transcript, matching: ["action", "todo", "to do", "next step", "follow up", "need to", "should"])
            : parsed.structuredActionItems.map { "[\($0.owner)] \($0.task)" }
        let suggestedTasks = buildSuggestedTasks(
            title: title,
            commitments: commitments,
            actionItems: actionItems,
            structuredItems: parsed.structuredActionItems
        )

        log.info("analysis complete type='\(meetingType)' decisions=\(decisions.count) actions=\(parsed.structuredActionItems.count) questions=\(parsed.openQuestions.count) risks=\(parsed.risks.count)")

        return MeetingAnalysis(
            summary:               parsed.summary.isEmpty ? fallbackSummary(transcript) : parsed.summary,
            meetingType:           meetingType,
            decisions:             decisions,
            openQuestions:         parsed.openQuestions,
            risks:                 parsed.risks,
            dependencies:          parsed.dependencies,
            commitments:           commitments,
            actionItems:           actionItems,
            structuredActionItems: parsed.structuredActionItems,
            suggestedTasks:        suggestedTasks
        )
    }

    // MARK: - Meeting Type Detection (synchronous, no AI)

    static func detectMeetingType(title: String, transcript: String) -> String {
        let combined = (title + " " + transcript.prefix(2000)).lowercased()

        // Standup signals
        if combined.contains("standup") || combined.contains("stand-up")
            || combined.contains("stand up") || combined.contains("daily sync")
            || (combined.contains("yesterday") && combined.contains("today") && combined.contains("blocker"))
            || (combined.contains("daily") && combined.contains("scrum")) {
            return MeetingType.standup.rawValue
        }
        // Sprint planning signals
        if combined.contains("sprint planning") || combined.contains("sprint backlog")
            || combined.contains("velocity") || combined.contains("story points")
            || (combined.contains("sprint") && combined.contains("planning")) {
            return MeetingType.sprintPlanning.rawValue
        }
        // Interview signals
        if combined.contains("interview") || combined.contains("candidate")
            || combined.contains("hiring") || combined.contains("resume")
            || combined.contains("tell me about yourself") {
            return MeetingType.interview.rawValue
        }
        // Sales call signals
        if combined.contains("sales call") || combined.contains("sales demo")
            || (combined.contains("prospect") && combined.contains("demo"))
            || combined.contains("proposal") || combined.contains("closing")
            || combined.contains("upsell") || combined.contains("churn") {
            return MeetingType.salesCall.rawValue
        }
        // Discovery call signals
        if combined.contains("discovery call") || combined.contains("discovery session")
            || (combined.contains("discovery") && combined.contains("requirements"))
            || combined.contains("pain point") || combined.contains("use case") {
            return MeetingType.discoveryCall.rawValue
        }
        // Customer support signals
        if combined.contains("support ticket") || combined.contains("customer support")
            || combined.contains("help desk") || combined.contains("incident")
            || combined.contains("bug report") {
            return MeetingType.customerSupport.rawValue
        }
        // Product review signals
        if combined.contains("product review") || combined.contains("product demo")
            || combined.contains("roadmap review") || combined.contains("feature review")
            || (combined.contains("product") && combined.contains("launch")) {
            return MeetingType.productReview.rawValue
        }
        // Executive review signals
        if combined.contains("executive") || combined.contains("board meeting")
            || combined.contains("leadership review") || combined.contains("all hands")
            || combined.contains("all-hands") || combined.contains("quarterly review") {
            return MeetingType.executiveReview.rawValue
        }
        return MeetingType.general.rawValue
    }

    // MARK: - Comprehensive Prompt Builder

    private func buildComprehensivePrompt(title: String, transcript: String, meetingType: String) -> String {
        let typeContext = Self.typeSpecificContext(for: meetingType)

        // Single-call path only reaches here for transcripts ≤ singleCallThreshold (12 000 chars).
        // No truncation needed — the routing in analyze() guarantees this.
        let trimmedTranscript = transcript

        return """
        You are analyzing a meeting recording. Respond with ONLY the structured sections below.

        MEETING TITLE: \(title)
        MEETING TYPE: \(meetingType)

        \(typeContext)

        TRANSCRIPT:
        \(trimmedTranscript)

        ---
        Respond using EXACTLY this format. Keep each section concise and factual.
        Do not add commentary outside the section headers.

        ## SUMMARY
        [3-5 sentence executive summary. Be specific to this meeting type. No bullet points.]

        ## ACTION ITEMS
        [One per line in format: OWNER: [name or Team] | TASK: [imperative description] | PRIORITY: [High/Medium/Low] | DUE: [date if mentioned, else TBD]]
        [Write "None" if no action items were discussed]

        ## DECISIONS
        [One decision per line starting with "- ". Only explicitly agreed decisions.]
        [Write "- None" if no decisions were made]

        ## OPEN QUESTIONS
        [One per line starting with "- ". Questions raised but not resolved.]
        [Write "- None" if no open questions]

        ## RISKS
        [One per line starting with "- ". Risks, concerns, or potential blockers mentioned.]
        [Write "- None" if no risks mentioned]

        ## DEPENDENCIES
        [One per line starting with "- ". Things the team is waiting on from others.]
        [Write "- None" if no dependencies mentioned]

        ## COMMITMENTS
        [One per line starting with "- ". Personal commitments made, e.g. "Alice will send the report by Monday".]
        [Write "- None" if no commitments made]
        """
    }

    /// Returns meeting-type-specific instructions for the summary section.
    static func typeSpecificContext(for meetingType: String) -> String {
        switch meetingType {
        case MeetingType.salesCall.rawValue:
            return """
            For this SALES CALL, focus the summary on:
            - Customer situation and pain points identified
            - Key objections and how they were handled
            - Deal stage progression
            - Agreed next steps toward closing
            """
        case MeetingType.standup.rawValue:
            return """
            For this STANDUP, focus the summary on:
            - Work completed since last standup
            - Work planned for today/next period
            - Blockers or impediments raised
            Keep it concise — 2-3 sentences maximum.
            """
        case MeetingType.sprintPlanning.rawValue:
            return """
            For this SPRINT PLANNING session, focus on:
            - Sprint goal agreed upon
            - Key stories or tasks committed to
            - Capacity and concerns raised
            """
        case MeetingType.interview.rawValue:
            return """
            For this INTERVIEW, focus on:
            - Key qualifications and strengths demonstrated
            - Any concerns or gaps identified
            - Overall assessment and recommended next steps
            Be balanced and objective.
            """
        case MeetingType.discoveryCall.rawValue:
            return """
            For this DISCOVERY CALL, focus on:
            - Customer goals and challenges revealed
            - Current pain points and use cases
            - Fit assessment and gaps identified
            - Agreed next steps
            """
        case MeetingType.customerSupport.rawValue:
            return """
            For this SUPPORT SESSION, focus on:
            - Issue or problem reported
            - Resolution or workaround provided
            - Follow-up items required
            """
        case MeetingType.productReview.rawValue:
            return """
            For this PRODUCT REVIEW, focus on:
            - Features or work reviewed
            - Feedback received
            - Changes requested or approved
            - Launch or release decisions
            """
        case MeetingType.executiveReview.rawValue:
            return """
            For this EXECUTIVE REVIEW, focus on:
            - Key metrics and performance discussed
            - Strategic decisions made
            - Priorities set or changed
            - Escalations or concerns raised
            """
        default:
            return """
            Write a comprehensive summary covering:
            - Main topics discussed
            - Key outcomes and decisions
            - Important next steps
            """
        }
    }

    // MARK: - Response Parser

    private struct ParsedResponse {
        var summary = ""
        var structuredActionItems: [ActionItemRecord] = []
        var decisions: [String] = []
        var openQuestions: [String] = []
        var risks: [String] = []
        var dependencies: [String] = []
        var commitments: [String] = []
    }

    private func parseComprehensiveResponse(_ text: String) -> ParsedResponse {
        var result = ParsedResponse()
        var currentSection = ""

        let lines = text.components(separatedBy: "\n")
        var summaryLines: [String] = []

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Section header detection
            if stripped.hasPrefix("## SUMMARY")       { currentSection = "summary";       continue }
            if stripped.hasPrefix("## ACTION ITEMS")  { currentSection = "actions";       continue }
            if stripped.hasPrefix("## DECISIONS")     { currentSection = "decisions";     continue }
            if stripped.hasPrefix("## OPEN QUESTIONS"){ currentSection = "questions";     continue }
            if stripped.hasPrefix("## RISKS")         { currentSection = "risks";         continue }
            if stripped.hasPrefix("## DEPENDENCIES")  { currentSection = "dependencies";  continue }
            if stripped.hasPrefix("## COMMITMENTS")   { currentSection = "commitments";   continue }

            guard !stripped.isEmpty, stripped != "None", stripped != "- None" else { continue }

            switch currentSection {
            case "summary":
                summaryLines.append(stripped)

            case "actions":
                if let item = parseActionItemLine(stripped) {
                    result.structuredActionItems.append(item)
                }

            case "decisions":
                if stripped.hasPrefix("- ") {
                    result.decisions.append(String(stripped.dropFirst(2)))
                } else {
                    result.decisions.append(stripped)
                }

            case "questions":
                if stripped.hasPrefix("- ") {
                    result.openQuestions.append(String(stripped.dropFirst(2)))
                } else {
                    result.openQuestions.append(stripped)
                }

            case "risks":
                if stripped.hasPrefix("- ") {
                    result.risks.append(String(stripped.dropFirst(2)))
                } else {
                    result.risks.append(stripped)
                }

            case "dependencies":
                if stripped.hasPrefix("- ") {
                    result.dependencies.append(String(stripped.dropFirst(2)))
                } else {
                    result.dependencies.append(stripped)
                }

            case "commitments":
                if stripped.hasPrefix("- ") {
                    result.commitments.append(String(stripped.dropFirst(2)))
                } else {
                    result.commitments.append(stripped)
                }
            default:
                break
            }
        }

        result.summary = summaryLines.joined(separator: " ")
        return result
    }

    // MARK: - Action Item Line Parser

    /// Parses a single action item line in the format:
    /// `OWNER: Alice | TASK: Send proposal | PRIORITY: High | DUE: Friday`
    private func parseActionItemLine(_ line: String) -> ActionItemRecord? {
        let parts = line.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count >= 2 else { return nil }

        var owner = "Team"
        var task = ""
        var priority = "Medium"
        var dueDate = ""

        for part in parts {
            let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key   = kv[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "OWNER":    owner    = value.isEmpty ? "Team" : value
            case "TASK":     task     = value
            case "PRIORITY": priority = value.isEmpty ? "Medium" : value.capitalized
            case "DUE":      dueDate  = (value.uppercased() == "TBD" || value.isEmpty) ? "" : value
            default: break
            }
        }

        guard !task.isEmpty else { return nil }
        return ActionItemRecord(owner: owner, task: task, priority: priority,
                                dueDateText: dueDate, rawText: line)
    }

    // MARK: - Keyword Fallback

    private func keywordFallback(title: String, transcript: String, meetingType: String) -> MeetingAnalysis {
        let summary       = fallbackSummary(transcript)
        let decisions     = extractCleanLines(from: transcript, matching: ["decided", "decision", "agreed", "approved"])
        let commitments   = extractCleanLines(from: transcript, matching: ["i will", "i'll", "we will", "follow up", "will send"])
        let actionItems   = extractCleanLines(from: transcript, matching: ["action", "todo", "to do", "next step", "follow up"])
        let suggestedTasks = buildSuggestedTasks(title: title, commitments: commitments,
                                                 actionItems: actionItems, structuredItems: [])
        return MeetingAnalysis(
            summary:               summary,
            meetingType:           meetingType,
            decisions:             decisions,
            openQuestions:         [],
            risks:                 [],
            dependencies:          [],
            commitments:           commitments,
            actionItems:           actionItems,
            structuredActionItems: [],
            suggestedTasks:        suggestedTasks
        )
    }

    private func emptyAnalysis() -> MeetingAnalysis {
        MeetingAnalysis(summary: "", meetingType: MeetingType.general.rawValue,
                        decisions: [], openQuestions: [], risks: [], dependencies: [],
                        commitments: [], actionItems: [], structuredActionItems: [],
                        suggestedTasks: [])
    }

    // MARK: - Helpers

    private func fallbackSummary(_ transcript: String) -> String {
        let sentences = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return sentences.prefix(3).joined(separator: ". ") + (sentences.isEmpty ? "" : ".")
    }

    /// Extracts lines matching any of the given keywords, then strips transcript
    /// formatting (timestamps, speaker labels) to produce readable action items.
    ///
    /// This replaces the old `extractLines` which returned raw timestamped lines
    /// verbatim — those were unreadable and contained full transcript paragraphs.
    private func extractCleanLines(from transcript: String, matching keywords: [String]) -> [String] {
        let candidates = transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(
            candidates
                .filter { line in
                    let lower = line.lowercased()
                    return keywords.contains { lower.contains($0) }
                }
                .map { Self.cleanTranscriptLine($0) }
                .filter { !$0.isEmpty }
                .prefix(8)
        )
    }

    /// Strips `[MM:SS]` timestamp prefix and `Speaker:` label from a transcript line,
    /// then truncates to the first sentence boundary within 200 chars.
    static func cleanTranscriptLine(_ raw: String) -> String {
        var text = raw
        // Remove leading timestamp — e.g. "[06:12] " or "[1:06:12] "
        if let range = text.range(of: #"^\[\d{1,2}:\d{2}(?::\d{2})?\]\s*"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        // Remove leading speaker label — e.g. "Me: " or "Participant: " or "Aditi: "
        if let range = text.range(of: #"^[A-Za-z][A-Za-z\s]{0,20}:\s*"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Truncate to first sentence within 200 chars to avoid huge chunks
        if text.count > 200 {
            let truncated = text.prefix(200)
            // Try to break at the last sentence-ending punctuation
            if let dotRange = truncated.range(of: #"[.!?]"#, options: [.regularExpression, .backwards]) {
                text = String(truncated[truncated.startIndex...dotRange.lowerBound])
            } else {
                // Break at last space to avoid cutting mid-word
                if let spaceRange = truncated.range(of: " ", options: .backwards) {
                    text = String(truncated[truncated.startIndex..<spaceRange.lowerBound]) + "…"
                } else {
                    text = String(truncated) + "…"
                }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildSuggestedTasks(
        title: String,
        commitments: [String],
        actionItems: [String],
        structuredItems: [ActionItemRecord]
    ) -> [String] {
        // Prefer structured item tasks when available
        if !structuredItems.isEmpty {
            let tasks = structuredItems.map { item in
                item.owner == "Team" || item.owner.isEmpty
                    ? item.task
                    : "[\(item.owner)] \(item.task)"
            }
            return Array(NSOrderedSet(array: tasks).array.compactMap { $0 as? String }.prefix(6))
        }

        let raw = (commitments + actionItems).map { item in
            item
                .replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(Action|TODO|To do|Next step):\s*"#, with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        if raw.isEmpty { return ["Review follow-ups from \(title)"] }
        return Array(NSOrderedSet(array: raw).array.compactMap { $0 as? String }.prefix(6))
    }
}
