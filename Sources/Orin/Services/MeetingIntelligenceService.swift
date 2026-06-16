import Foundation
import OSLog

// MARK: - MeetingAnalysis

struct MeetingAnalysis {
    var summary: String
    var conservativeSummary: String
    var meetingType: String
    var decisions: [String]
    var openQuestions: [String]
    var risks: [String]
    var dependencies: [String]
    var commitments: [String]
    var actionItems: [String]
    var structuredActionItems: [ActionItemRecord]
    var suggestedTasks: [String]
    var evidencedDecisions: [EvidencedItem]
    var evidencedDiscussionPoints: [EvidencedItem]
    var evidencedFollowUps: [EvidencedItem]
    var hallucinationReport: HallucinationReport?

    var evidence: MeetingAnalysisEvidence {
        MeetingAnalysisEvidence(
            conservativeSummary:       conservativeSummary,
            evidencedDecisions:        evidencedDecisions,
            evidencedDiscussionPoints: evidencedDiscussionPoints,
            evidencedFollowUps:        evidencedFollowUps,
            hallucinationReport:       hallucinationReport
        )
    }
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
        let meCount  = segments.filter { $0.speakerLabel == "Me" }.count
        let parCount = segments.filter { $0.speakerLabel != "Me" }.count
        print("[MeetingIntelligence] transcript chars=\(timelineText.count) segments=\(segments.count) Me=\(meCount) Participant=\(parCount) for '\(title)'")

        // Long meetings: route directly to segment-aware chunker (utterance boundaries, not newlines)
        if timelineText.count > TranscriptChunker.singleCallThreshold {
            let meetingType = MeetingIntelligenceService.detectMeetingType(title: title, transcript: timelineText)
            let chunks = TranscriptChunker.chunks(of: segments, meetingStart: meetingStart)
            print("[MeetingIntelligence] segment-aware chunking: \(segments.count) segments → \(chunks.count) chunks")
            return await analyzeChunked(title: title, chunks: chunks, meetingType: meetingType)
        }

        return await analyzeSingleCall(
            title: title, transcript: timelineText,
            meetingType: MeetingIntelligenceService.detectMeetingType(title: title, transcript: timelineText)
        )
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
        return await analyzeChunked(title: title, chunks: chunks, meetingType: meetingType)
    }

    private func analyzeChunked(
        title: String,
        chunks: [String],
        meetingType: String
    ) async -> MeetingAnalysis {
        log.info("chunked analysis: \(chunks.count) chunks for title='\(title)'")

        // Phase 1: Extract from all chunks concurrently.
        // Cloud APIs process requests in parallel; Ollama queues and serializes internally
        // so total inference time is the same but network overhead overlaps.
        let service = aiService
        var ordered = [ChunkAnalysis?](repeating: nil, count: chunks.count)
        await withTaskGroup(of: (Int, ChunkAnalysis).self) { group in
            for (i, chunk) in chunks.enumerated() {
                group.addTask {
                    let ca = await TranscriptChunker.analyzeChunk(
                        chunk, index: i, totalChunks: chunks.count,
                        meetingType: meetingType, aiService: service
                    )
                    return (i, ca)
                }
            }
            for await (i, ca) in group { ordered[i] = ca }
        }
        let chunkAnalyses = ordered.compactMap { $0 }

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

        // --- Proof-run diagnostic dump ---
        let fullTranscript = chunks.joined(separator: "\n")
        print("[ProofRun] ── FINAL SUMMARY ──────────────────────────────────────────")
        print(summary)
        print("[ProofRun] ── ACTION ITEMS (\(allStructured.count)) ──────────────────────────────")
        if allStructured.isEmpty {
            print("  (none)")
        } else {
            for item in allStructured {
                print("  [\(item.owner)] \(item.task) | priority=\(item.priority) due=\(item.dueDateText.isEmpty ? "TBD" : item.dueDateText)")
            }
        }
        print("[ProofRun] ── DECISIONS (\(allDecisions.count)) ──────────────────────────────────")
        if allDecisions.isEmpty {
            print("  (none)")
        } else {
            for d in allDecisions { print("  • \(d)") }
        }
        print("[ProofRun] ── HALLUCINATION CHECK ──────────────────────────────────────")
        let transcriptLower = fullTranscript.lowercased()
        let summaryWords = summary.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { w in w.count >= 4 && w.first?.isUppercase == true && w != title }
        var flagged: [String] = []
        for word in summaryWords {
            if !transcriptLower.contains(word.lowercased()) && !flagged.contains(word) {
                flagged.append(word)
            }
        }
        if flagged.isEmpty {
            print("  PASS — all summary terms found in transcript")
        } else {
            print("  FLAGGED terms not found in transcript: \(flagged.joined(separator: ", "))")
        }
        print("[ProofRun] ─────────────────────────────────────────────────────────────")

        return MeetingAnalysis(
            summary:                   summary,
            conservativeSummary:       "",
            meetingType:               meetingType,
            decisions:                 allDecisions,
            openQuestions:             allOpenQuestions,
            risks:                     allRisks,
            dependencies:              allDependencies,
            commitments:               allCommitments,
            actionItems:               allActionItems,
            structuredActionItems:     allStructured,
            suggestedTasks:            suggestedTasks,
            evidencedDecisions:        [],
            evidencedDiscussionPoints: [],
            evidencedFollowUps:        [],
            hallucinationReport:       nil
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
        let result = await aiService.generate(prompt: prompt, maxTokens: 900)

        log.info("AI response: fallback=\(result.fallbackUsed) chars=\(result.text.count) preview='\(result.text.prefix(120))'")

        if result.fallbackUsed || result.text.isEmpty {
            log.warning("AI unavailable — using keyword fallback")
            return keywordFallback(title: title, transcript: transcript, meetingType: meetingType)
        }

        // Dump raw phi3 response for debugging — read at /tmp/orin_phi3_raw.txt
        try? result.text.write(to: URL(fileURLWithPath: "/tmp/orin_phi3_raw.txt"),
                               atomically: true, encoding: .utf8)

        // Step 3: Parse structured response (pass transcript for snippet verification)
        let parsed = parseComprehensiveResponse(result.text, transcript: transcript)

        let decisions     = parsed.decisions.isEmpty
            ? extractCleanLines(from: transcript, matching: ["decided", "decision", "agreed", "approved", "will proceed", "confirmed"])
            : parsed.decisions
        let commitments   = parsed.commitments.isEmpty
            ? extractCleanLines(from: transcript, matching: ["i will", "i'll", "we will", "will send", "will prepare", "will schedule"])
            : parsed.commitments
        // Filter then deduplicate — mirrors what the chunked path does per-chunk.
        var validStructured = TranscriptChunker.deduplicateActionItems(
            parsed.structuredActionItems.filter { TranscriptChunker.isMeaningfulActionItem(task: $0.task) }
        )
        let actionItems: [String]
        if validStructured.isEmpty {
            actionItems = extractCleanLines(
                from: transcript,
                matching: ["action", "todo", "to do", "next step", "follow up", "need to", "should"]
            )
        } else {
            actionItems = validStructured.map { "[\($0.owner)] \($0.task)" }
        }
        let suggestedTasks = buildSuggestedTasks(
            title: title, commitments: commitments,
            actionItems: actionItems, structuredItems: validStructured
        )

        // Swift-side evidence computation: check each extracted item against the
        // original transcript. phi3 extracts items; we measure whether they're real.
        let evidencedDecisions = evidenceItems(parsed.decisions, in: transcript)
        let evidencedPoints    = evidenceItems(
            parsed.evidencedDiscussionPoints.map { $0.text }, in: transcript)
        let evidencedFollowUps = evidenceItems(
            parsed.evidencedFollowUps.map { $0.text }, in: transcript)
        for i in validStructured.indices {
            validStructured[i].isSupported =
                snippetSupported(validStructured[i].task, in: transcript)
            validStructured[i].confidence =
                validStructured[i].isSupported ? .high : .low
        }

        let report = computeHallucinationReport(
            decisions: evidencedDecisions,
            points:    evidencedPoints,
            followUps: evidencedFollowUps,
            actions:   validStructured
        )

        // Conservative summary: only HIGH-confidence (transcript-supported) items.
        let highFacts = (evidencedDecisions + evidencedPoints + evidencedFollowUps)
            .filter { $0.confidence == .high }.map { $0.text }
        let conservativeSummary = highFacts.isEmpty
            ? parsed.summary
            : highFacts.prefix(3).joined(separator: ". ") + "."

        print("[HallucinationReport] model=phi3 total=\(report.totalItems) supported=\(report.supportedItems) unsupported=\(report.unsupportedItems) rate=\(String(format: "%.0f", report.hallucinationRate * 100))%")
        print("[HallucinationReport] currentSummary=\(parsed.summary.count)chars conservativeSummary=\(conservativeSummary.count)chars")

        log.info("analysis complete type='\(meetingType)' decisions=\(decisions.count) actions=\(validStructured.count) hallucination=\(String(format: "%.0f", report.hallucinationRate * 100))%")

        return MeetingAnalysis(
            summary:                   parsed.summary.isEmpty ? fallbackSummary(transcript) : parsed.summary,
            conservativeSummary:       conservativeSummary,
            meetingType:               meetingType,
            decisions:                 decisions,
            openQuestions:             parsed.openQuestions,
            risks:                     parsed.risks,
            dependencies:              parsed.dependencies,
            commitments:               commitments,
            actionItems:               actionItems,
            structuredActionItems:     validStructured,
            suggestedTasks:            suggestedTasks,
            evidencedDecisions:        evidencedDecisions,
            evidencedDiscussionPoints: evidencedPoints,
            evidencedFollowUps:        evidencedFollowUps,
            hallucinationReport:       report
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
        let trimmedTranscript = transcript

        return """
        You are a meeting notes assistant. Fill in the five sections below using ONLY facts explicitly stated in the transcript. Do not infer. Do not write emails. Do not add commentary outside the sections.

        MEETING TITLE: \(title)
        TRANSCRIPT:
        \(trimmedTranscript)

        Fill in these five sections:

        ## SUMMARY
        Write 2-3 sentences covering what was discussed.

        ## DISCUSSION POINTS
        List each topic as a short bullet.

        ## ACTION ITEMS
        Only create an action item when a speaker explicitly commits to a specific task, follow-up, or deliverable.
        Do NOT create action items from acknowledgements (yeah, right, okay, sure), opinions, discussion topics, or questions without an owner.
        Write "None" if no explicit commitments were made.
        For each real action item: OWNER: name | TASK: verb-first task | PRIORITY: High/Medium/Low | DUE: date or TBD

        ## DECISIONS
        List each decision as a short bullet.

        ## FOLLOW-UPS
        List each follow-up as a short bullet.
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
        var conservativeSummary = ""
        var structuredActionItems: [ActionItemRecord] = []
        var decisions: [String] = []
        var openQuestions: [String] = []
        var risks: [String] = []
        var dependencies: [String] = []
        var commitments: [String] = []
        var evidencedDecisions: [EvidencedItem] = []
        var evidencedDiscussionPoints: [EvidencedItem] = []
        var evidencedFollowUps: [EvidencedItem] = []
    }

    private func parseComprehensiveResponse(_ text: String, transcript: String) -> ParsedResponse {
        var result = ParsedResponse()
        var currentSection = ""
        var summaryLines: [String] = []
        var conservativeLines: [String] = []
        var preSectionLines: [String] = []   // phi3 often outputs summary before first ## header

        for line in text.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)

            var content = stripped
            if let (section, inline) = sectionHeader(from: stripped) {
                currentSection = section
                content = inline
            }

            guard !content.isEmpty, content != "None", content != "- None" else { continue }

            // Filter phi3 instruction echoes, null results, and email hallucinations
            let lower = content.lowercased()
            if lower.hasPrefix("no explicit") || lower.hasPrefix("no clear")
               || lower.hasPrefix("no follow") || lower.hasPrefix("none of the")
               || lower.contains("not mentioned") || lower.contains("no action item")
               || lower.contains("sentences summary")
               || lower.hasPrefix("dear ") || lower.hasPrefix("subject:")
               || lower.hasPrefix("to: ") || lower.hasPrefix("from: ")
               || lower.hasPrefix("i hope") || lower.hasPrefix("i trust this")
               || lower.hasPrefix("[text]")
               || lower.contains("decision after meeting")
               || lower.contains("decision made immediately")
               || lower.contains("decision agreed upon immediately")
               || lower.contains("prior transcript") || lower.contains("not provided herein") { continue }

            switch currentSection {
            case "summary":
                summaryLines.append(content)

            case "conservativeSummary":
                conservativeLines.append(content)

            case "actions":
                let (conf, withoutConf) = extractConfidence(from: content)
                let (itemText, snippet) = extractSnippet(from: withoutConf)
                if var item = parseActionItemLine(itemText) {
                    item.confidence  = conf
                    item.snippet     = snippet
                    item.isSupported = snippetSupported(snippet, in: transcript)
                    result.structuredActionItems.append(item)
                }

            case "decisions":
                let (conf, withoutConf) = extractConfidence(from: content)
                let (itemText, snippet) = extractSnippet(from: withoutConf)
                let clean = itemText.hasPrefix("- ") ? String(itemText.dropFirst(2)) : itemText
                guard !clean.isEmpty else { break }
                result.decisions.append(clean)
                result.evidencedDecisions.append(EvidencedItem(
                    text: clean, confidence: conf, snippet: snippet,
                    isSupported: snippetSupported(snippet, in: transcript)))

            case "discussionPoints":
                let (conf, withoutConf) = extractConfidence(from: content)
                let (itemText, snippet) = extractSnippet(from: withoutConf)
                let clean = itemText.hasPrefix("- ") ? String(itemText.dropFirst(2)) : itemText
                guard !clean.isEmpty else { break }
                result.evidencedDiscussionPoints.append(EvidencedItem(
                    text: clean, confidence: conf, snippet: snippet,
                    isSupported: snippetSupported(snippet, in: transcript)))

            case "followUps":
                let (conf, withoutConf) = extractConfidence(from: content)
                let (itemText, snippet) = extractSnippet(from: withoutConf)
                let clean = itemText.hasPrefix("- ") ? String(itemText.dropFirst(2)) : itemText
                guard !clean.isEmpty else { break }
                result.evidencedFollowUps.append(EvidencedItem(
                    text: clean, confidence: conf, snippet: snippet,
                    isSupported: snippetSupported(snippet, in: transcript)))

            case "questions":
                let (_, rest) = extractConfidence(from: content)
                let (itemText, _) = extractSnippet(from: rest)
                let clean = itemText.hasPrefix("- ") ? String(itemText.dropFirst(2)) : itemText
                if !clean.isEmpty { result.openQuestions.append(clean) }

            case "risks":
                let (_, rest) = extractConfidence(from: content)
                let (itemText, _) = extractSnippet(from: rest)
                let clean = itemText.hasPrefix("- ") ? String(itemText.dropFirst(2)) : itemText
                if !clean.isEmpty { result.risks.append(clean) }

            case "dependencies":
                let (_, rest) = extractConfidence(from: content)
                let (itemText, _) = extractSnippet(from: rest)
                let clean = itemText.hasPrefix("- ") ? String(itemText.dropFirst(2)) : itemText
                if !clean.isEmpty { result.dependencies.append(clean) }

            case "commitments":
                let (_, rest) = extractConfidence(from: content)
                let (itemText, _) = extractSnippet(from: rest)
                let clean = itemText.hasPrefix("- ") ? String(itemText.dropFirst(2)) : itemText
                if !clean.isEmpty { result.commitments.append(clean) }

            default:
                // Collect substantive pre-header text — phi3 sometimes outputs its
                // summary as free text before the first section marker.
                // Cap at 3 lines so a malformed response doesn't dump everything here.
                if currentSection == "" && content.count > 40 && preSectionLines.count < 3 {
                    preSectionLines.append(content)
                }
            }
        }

        // Use pre-header text as summary when phi3 didn't emit a recognised SUMMARY header
        if summaryLines.isEmpty {
            summaryLines = preSectionLines
        }

        result.summary             = summaryLines.joined(separator: " ")
        result.conservativeSummary = conservativeLines.joined(separator: " ")
        return result
    }

    // MARK: - Section Header Detection

    // Normalises any LLM header style → (sectionName, inlineContent).
    // Handles: "## SUMMARY", "**EXECUTIVE SUMMARY:**", "[SUMMARY]", "[ACTION ITEMS] text"
    private func sectionHeader(from line: String) -> (String, String)? {
        if line.hasPrefix("#") || line.hasPrefix("*") {
            var s = line
            while let c = s.first, c == "#" || c == "*" || c == " " { s.removeFirst() }
            let headerPart: String
            var inlinePart = ""
            if let colonIdx = s.firstIndex(of: ":") {
                headerPart = String(s[s.startIndex..<colonIdx])
                inlinePart = String(s[s.index(after: colonIdx)...])
                    .trimmingCharacters(in: .init(charactersIn: "*: "))
            } else {
                headerPart = s
            }
            let name = headerPart.trimmingCharacters(in: .init(charactersIn: "* ")).uppercased()
            guard let section = sectionName(from: name) else { return nil }
            return (section, inlinePart)
        }

        // [SECTION NAME] or [SECTION NAME] inline content
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let bracketContent = String(line[line.index(after: line.startIndex)..<close])
                .trimmingCharacters(in: .whitespaces).uppercased()
            if bracketContent.hasPrefix("END") { return nil }   // [END OF SECTION] markers
            let inlinePart = String(line[line.index(after: close)...])
                .trimmingCharacters(in: .init(charactersIn: " :"))
            guard let section = sectionName(from: bracketContent) else { return nil }
            return (section, inlinePart)
        }

        // Plain "SECTION NAME: inline content" (no prefix markers) — phi3 sometimes
        // emits raw headers like "SUMMARY: text" or "ACTION ITEMS:  "
        if let colonIdx = line.firstIndex(of: ":") {
            let candidate = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces).uppercased()
            // Only match if candidate is a known section name (avoids "OWNER:", "Me:", etc.)
            if let section = sectionName(from: candidate) {
                let inlinePart = String(line[line.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                return (section, inlinePart)
            }
        }

        return nil
    }

    private func sectionName(from name: String) -> String? {
        if name.hasPrefix("CONSERVATIVE")                            { return "conservativeSummary" }
        if name.hasPrefix("CURRENT SUMMARY")
        || name.hasPrefix("EXECUTIVE SUMMARY")
        || name == "SUMMARY"                                         { return "summary" }
        if name.hasPrefix("DISCUSSION POINT")                        { return "discussionPoints" }
        if name.hasPrefix("ACTION ITEM") || name == "ACTIONS"        { return "actions" }
        if name.hasPrefix("DECISION")                                { return "decisions" }
        if name.hasPrefix("FOLLOW")                                  { return "followUps" }
        if name.hasPrefix("OPEN Q")                                  { return "questions" }
        if name.hasPrefix("RISK")                                    { return "risks" }
        if name.hasPrefix("DEPEND")                                  { return "dependencies" }
        if name.hasPrefix("COMMIT")                                  { return "commitments" }
        return nil
    }

    // MARK: - Evidence Extraction Helpers

    // Strips a leading [HIGH/MEDIUM/LOW] marker from a line.
    private func extractConfidence(from line: String) -> (ConfidenceLevel, String) {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = s.uppercased()
        for (tag, level) in [("[HIGH]", ConfidenceLevel.high),
                              ("[MEDIUM]", .medium),
                              ("[LOW]", .low)] {
            if upper.hasPrefix(tag) {
                let rest = String(s.dropFirst(tag.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (level, rest)
            }
        }
        return (.medium, s)
    }

    // Splits a line at "| SOURCE: ..." and returns (content, snippet).
    private func extractSnippet(from line: String) -> (String, String) {
        guard let range = line.range(of: "| SOURCE:", options: .caseInsensitive) else {
            return (line.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let content = String(line[line.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = String(line[range.upperBound...])
            .trimmingCharacters(in: .init(charactersIn: " \"'"))
        let snippet = raw.hasSuffix("\"") || raw.hasSuffix("'")
            ? String(raw.dropLast()) : raw
        return (content, snippet)
    }

    // Converts plain text items into EvidencedItems with Swift-computed confidence.
    private func evidenceItems(_ items: [String], in transcript: String) -> [EvidencedItem] {
        items.compactMap { text -> EvidencedItem? in
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let supported = snippetSupported(cleaned, in: transcript)
            return EvidencedItem(
                text:        cleaned,
                confidence:  supported ? .high : .low,
                snippet:     cleaned,
                isSupported: supported
            )
        }
    }

    // Returns true when a verbatim or near-verbatim match of `snippet` exists in `transcript`.
    private func snippetSupported(_ snippet: String, in transcript: String) -> Bool {
        guard !snippet.isEmpty else { return false }
        let norm = snippet.lowercased().trimmingCharacters(in: .init(charactersIn: "\"' .,"))
        let t    = transcript.lowercased()
        if t.contains(norm) { return true }
        // Partial match: first 4 consecutive words
        let words = norm.split(separator: " ").map(String.init)
        guard words.count >= 3 else { return t.contains(norm) }
        for i in 0..<max(1, words.count - 2) {
            let window = words[i..<min(i + 4, words.count)].joined(separator: " ")
            if t.contains(window) { return true }
        }
        return false
    }

    // Builds a hallucination report from all evidenced items in this analysis.
    private func computeHallucinationReport(
        decisions: [EvidencedItem],
        points: [EvidencedItem],
        followUps: [EvidencedItem],
        actions: [ActionItemRecord]
    ) -> HallucinationReport {
        var total = 0
        var supported = 0
        for item in decisions + points + followUps {
            total += 1
            if item.isSupported { supported += 1 }
        }
        for item in actions {
            total += 1
            if item.isSupported { supported += 1 }
        }
        let rate = total > 0 ? Double(total - supported) / Double(total) : 0.0
        return HallucinationReport(
            modelUsed: "phi3",
            totalItems: total,
            supportedItems: supported,
            unsupportedItems: total - supported,
            hallucinationRate: rate,
            analysisTimestamp: Date()
        )
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
            case "TASK":
                // Strip embedded "Priority: ..." or "Due: ..." that phi3 appends inside the task value
                var taskVal = value
                for suffix in [". Priority:", "; Priority:", ". Due:", "; Due:", ". priority:"] {
                    if let r = taskVal.range(of: suffix, options: .caseInsensitive) {
                        taskVal = String(taskVal[..<r.lowerBound])
                    }
                }
                task = taskVal.trimmingCharacters(in: .whitespacesAndNewlines)
            case "PRIORITY": priority = value.isEmpty ? "Medium" : value.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces).capitalized ?? "Medium"
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
            summary:                   summary,
            conservativeSummary:       "",
            meetingType:               meetingType,
            decisions:                 decisions,
            openQuestions:             [],
            risks:                     [],
            dependencies:              [],
            commitments:               commitments,
            actionItems:               actionItems,
            structuredActionItems:     [],
            suggestedTasks:            suggestedTasks,
            evidencedDecisions:        [],
            evidencedDiscussionPoints: [],
            evidencedFollowUps:        [],
            hallucinationReport:       nil
        )
    }

    private func emptyAnalysis() -> MeetingAnalysis {
        MeetingAnalysis(
            summary: "", conservativeSummary: "",
            meetingType: MeetingType.general.rawValue,
            decisions: [], openQuestions: [], risks: [], dependencies: [],
            commitments: [], actionItems: [], structuredActionItems: [],
            suggestedTasks: [], evidencedDecisions: [], evidencedDiscussionPoints: [],
            evidencedFollowUps: [], hallucinationReport: nil
        )
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
