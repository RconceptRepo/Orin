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
        guard !trimmed.isEmpty else {
            return emptyAnalysis()
        }

        // Step 1: Detect meeting type (local — no AI)
        let meetingType = MeetingIntelligenceService.detectMeetingType(title: title, transcript: trimmed)

        // Step 2: Build comprehensive structured prompt
        let prompt = buildComprehensivePrompt(title: title, transcript: trimmed, meetingType: meetingType)

        // Step 3: Single AI call
        let result = await aiService.generate(prompt: prompt, maxTokens: 1500)

        if result.fallbackUsed || result.text.isEmpty {
            log.warning("AI unavailable — using keyword fallback")
            return keywordFallback(title: title, transcript: trimmed, meetingType: meetingType)
        }

        // Step 4: Parse structured response
        let parsed = parseComprehensiveResponse(result.text)

        // If parsing produced almost nothing, run keyword fallback for missing sections
        let decisions     = parsed.decisions.isEmpty
            ? extractLines(from: trimmed, matching: ["decided", "decision", "agreed", "approved", "will proceed", "confirmed"])
            : parsed.decisions
        let commitments   = parsed.commitments.isEmpty
            ? extractLines(from: trimmed, matching: ["i will", "i'll", "we will", "i'll", "will send", "will prepare", "will schedule"])
            : parsed.commitments
        let actionItems   = parsed.structuredActionItems.isEmpty
            ? extractLines(from: trimmed, matching: ["action", "todo", "to do", "next step", "follow up", "need to", "should"])
            : parsed.structuredActionItems.map { "[\($0.owner)] \($0.task)" }
        let suggestedTasks = buildSuggestedTasks(
            title: title,
            commitments: commitments,
            actionItems: actionItems,
            structuredItems: parsed.structuredActionItems
        )

        log.info("analysis complete type='\(meetingType)' decisions=\(decisions.count) actions=\(parsed.structuredActionItems.count) questions=\(parsed.openQuestions.count) risks=\(parsed.risks.count)")

        return MeetingAnalysis(
            summary:               parsed.summary.isEmpty ? fallbackSummary(trimmed) : parsed.summary,
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

        // Trim transcript to fit context window
        let maxChars = 6000
        let trimmedTranscript = transcript.count > maxChars
            ? String(transcript.prefix(maxChars)) + "\n[...transcript continues...]"
            : transcript

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
        let decisions     = extractLines(from: transcript, matching: ["decided", "decision", "agreed", "approved"])
        let commitments   = extractLines(from: transcript, matching: ["i will", "i'll", "we will", "follow up", "will send"])
        let actionItems   = extractLines(from: transcript, matching: ["action", "todo", "to do", "next step", "follow up"])
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

    private func extractLines(from transcript: String, matching keywords: [String]) -> [String] {
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
                .prefix(8)
        )
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
