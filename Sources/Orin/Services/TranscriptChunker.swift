import Foundation
import OSLog

// MARK: - ChunkAnalysis

/// Structured data extracted from a single transcript chunk.
/// Accumulated across all chunks then merged into a final `MeetingAnalysis`.
struct ChunkAnalysis {
    var index: Int
    var decisions: [String]            = []
    var openQuestions: [String]        = []
    var risks: [String]                = []
    var dependencies: [String]         = []
    var commitments: [String]          = []
    var actionItems: [String]          = []
    var structuredActionItems: [ActionItemRecord] = []
    /// 1-3 bullet-point summary of the chunk used by the synthesis prompt.
    var keyPoints: [String]            = []
}

// MARK: - TranscriptChunker
//
// Splits long transcripts into overlapping chunks, extracts structured data
// from each chunk in sequence, then synthesizes a final executive summary.
//
// # Meeting length → chunk count (at chunkSize = 5 000 chars ≈ 7-8 min of speech)
//
//   15 min  →  ~9 750 chars  →  single call (below singleCallThreshold)
//   30 min  → ~19 500 chars  →  4 chunks + 1 synthesis = 5 calls
//   60 min  → ~39 000 chars  →  8 chunks + 1 synthesis = 9 calls
//   90 min  → ~58 500 chars  → 12 chunks + 1 synthesis = 13 calls
//  120 min  → ~78 000 chars  → 16 chunks + 1 synthesis = 17 calls
//
// # Provider context limits
//
//   Ollama (llama3 default) :  8 192 tokens ≈ 32 000 chars — fits one 7-min chunk easily
//   GPT-4o-mini             : 128 000 tokens — could fit entire meeting
//   Claude Haiku            : 200 000 tokens — could fit entire meeting
//
//   We optimise for Ollama (the default, local provider) so chunks stay well inside
//   its 8 192-token context window.

enum TranscriptChunker {

    // MARK: - Thresholds

    /// Transcripts at or below this length use a single comprehensive prompt.
    /// ~18 min of speech at 130 wpm.
    static let singleCallThreshold = 12_000

    /// Target characters per chunk. At 130 wpm → ~7-8 min of speech per chunk.
    static let chunkSize = 5_000

    /// Characters of overlap between consecutive chunks to preserve cross-boundary context.
    static let overlapSize = 500

    private static let log = Logger(subsystem: "com.clavrit.orin", category: "TranscriptChunker")

    // MARK: - Chunking

    /// Splits `segments` into overlapping chunks at speaker-change boundaries.
    ///
    /// Each chunk is a formatted timeline string (via `ConversationTimelineBuilder.formatted`).
    /// Chunks are built by accumulating utterances until `chunkSize` is reached, then
    /// snapping back to the last speaker-change boundary so no utterance is split.
    /// The last `utteranceOverlap` utterances of each chunk are carried into the next
    /// chunk to preserve cross-boundary context.
    ///
    /// When both speakers exist in the source, every chunk is guaranteed to contain at
    /// least one utterance from each speaker — the speaker-boundary split point ensures
    /// a completed alternation is always included before the cut.
    ///
    /// Returns a single-element array when estimated length ≤ `singleCallThreshold`.
    static func chunks(of segments: [TranscriptSegment], meetingStart: Date?) -> [String] {
        guard !segments.isEmpty else { return [] }

        let estimatedLength = segments.reduce(0) { $0 + $1.text.count + 20 }
        guard estimatedLength > singleCallThreshold else {
            return [ConversationTimelineBuilder.formatted(segments, meetingStart: meetingStart)]
        }

        let utteranceOverlap = 3
        var result: [String] = []
        var startIndex = 0

        while startIndex < segments.count {
            var accumulated = 0
            var endIndex = startIndex

            while endIndex < segments.count {
                accumulated += segments[endIndex].text.count + 20
                if accumulated >= chunkSize { break }
                endIndex += 1
            }

            if endIndex >= segments.count {
                endIndex = segments.count - 1
            } else {
                endIndex = lastSpeakerBoundary(in: segments, from: startIndex, upTo: endIndex)
            }

            let chunkSegments = Array(segments[startIndex...endIndex])
            let chunkText = ConversationTimelineBuilder.formatted(chunkSegments, meetingStart: meetingStart)
            result.append(chunkText)

            let chunkIdx  = result.count
            let lines     = chunkText.components(separatedBy: "\n").filter { !$0.isEmpty }
            let meCount   = lines.filter { $0.contains("] Me:") }.count
            let parCount  = lines.filter { $0.contains("] Participant:") }.count
            print("[Chunker] chunk \(chunkIdx): \(chunkText.count) chars | \(lines.count) utterances | Me=\(meCount) Participant=\(parCount)")
            print("[Chunker]   first: \(lines.first.map { String($0.prefix(110)) } ?? "(empty)")")
            print("[Chunker]   last:  \(lines.last.map { String($0.prefix(110)) } ?? "(empty)")")

            let nextStart = endIndex + 1
            guard nextStart < segments.count else { break }
            startIndex = max(nextStart - utteranceOverlap, startIndex + 1)
        }

        return result
    }

    /// Returns the index of the last segment that ends a completed speaker turn,
    /// walking backwards from `end` to find a speaker-change boundary.
    /// Falls back to `end` if no boundary is found (single-speaker section).
    private static func lastSpeakerBoundary(in segments: [TranscriptSegment], from start: Int, upTo end: Int) -> Int {
        for i in stride(from: end, through: start + 1, by: -1) {
            if segments[i].speakerLabel != segments[i - 1].speakerLabel {
                return i - 1
            }
        }
        return end
    }

    /// Splits `transcript` into overlapping chunks aligned to line boundaries.
    ///
    /// Lines starting with a timestamp (`[MM:SS]`) are preferred split points so that
    /// utterances are never cut mid-sentence.
    ///
    /// Returns `[transcript]` (single chunk) when length ≤ `singleCallThreshold`.
    static func chunks(of transcript: String) -> [String] {
        guard transcript.count > singleCallThreshold else { return [transcript] }

        let lines = transcript.components(separatedBy: "\n")
        var result: [String] = []
        var currentLines: [String] = []
        var currentLength = 0

        for line in lines {
            let lineLen = line.count + 1  // +1 for the newline
            currentLines.append(line)
            currentLength += lineLen

            if currentLength >= chunkSize {
                result.append(currentLines.joined(separator: "\n"))
                // Keep the trailing lines that represent `overlapSize` chars for context
                currentLines = trailingLines(of: currentLines, targetChars: overlapSize)
                currentLength = currentLines.map { $0.count + 1 }.reduce(0, +)
            }
        }
        if !currentLines.isEmpty {
            result.append(currentLines.joined(separator: "\n"))
        }
        return result
    }

    // MARK: - Chunk Extraction

    /// Extracts structured data from a single transcript chunk.
    ///
    /// Uses a lightweight extraction-only prompt (no full summary), which keeps
    /// response sizes small and within Ollama's token limits.
    static func analyzeChunk(
        _ chunk: String,
        index: Int,
        totalChunks: Int,
        meetingType: String,
        aiService: AIService
    ) async -> ChunkAnalysis {
        let prompt = buildExtractionPrompt(chunk: chunk, index: index, total: totalChunks, meetingType: meetingType)
        let result = await aiService.generate(prompt: prompt, maxTokens: 500)

        if result.fallbackUsed || result.text.isEmpty {
            log.warning("chunk \(index + 1)/\(totalChunks): AI unavailable — using keyword fallback")
            return keywordChunkFallback(chunk, index: index)
        }

        var analysis = parseChunkResponse(result.text)
        analysis.structuredActionItems = analysis.structuredActionItems
            .filter { isMeaningfulActionItem(task: $0.task) }
        analysis.actionItems = analysis.structuredActionItems
            .map { "[\($0.owner)] \($0.task)" }
        analysis.index = index
        log.debug("chunk \(index + 1)/\(totalChunks): decisions=\(analysis.decisions.count) actions=\(analysis.structuredActionItems.count) keyPoints=\(analysis.keyPoints.count)")
        return analysis
    }

    // MARK: - Synthesis

    /// Synthesizes a final executive summary from all chunk analyses.
    ///
    /// Sends only the key-points (1-3 bullets per chunk) plus outcome counts to the AI —
    /// NOT the full transcript — so the synthesis call is always fast and token-efficient.
    static func synthesize(
        chunks: [ChunkAnalysis],
        title: String,
        meetingType: String,
        aiService: AIService
    ) async -> String {
        let allDecisions = deduplicateStrings(chunks.flatMap(\.decisions))
        let allActions   = deduplicateActionItems(chunks.flatMap(\.structuredActionItems))
        let keyPointsText = chunks
            .sorted { $0.index < $1.index }
            .flatMap { chunk in chunk.keyPoints.map { "  • \($0)" } }
            .joined(separator: "\n")

        let prompt = buildSynthesisPrompt(
            keyPointsText: keyPointsText,
            decisionsCount: allDecisions.count,
            actionsCount: allActions.count,
            title: title
        )

        let result = await aiService.generate(prompt: prompt, maxTokens: 350)
        if result.fallbackUsed || result.text.isEmpty {
            log.warning("synthesis: AI unavailable — using key-points fallback summary")
            return keyPointsSummary(from: chunks)
        }
        return result.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Deduplication

    /// Removes duplicate `ActionItemRecord` entries.
    ///
    /// Two items are considered duplicates when they share:
    ///   - The same owner (case-insensitive), AND
    ///   - At least 60% token overlap in the task description (Jaccard similarity)
    ///
    /// When duplicates exist, the entry with more detail (non-empty due date or
    /// specific owner vs. "Team") is preferred.
    static func deduplicateActionItems(_ items: [ActionItemRecord]) -> [ActionItemRecord] {
        var kept: [ActionItemRecord] = []
        for item in items {
            if let idx = kept.firstIndex(where: { isDuplicateAction($0, item) }) {
                // Keep the more detailed one
            let score0 = detailScore(kept[idx])
            let score1 = detailScore(item)
                if score1 > score0 { kept[idx] = item }
            } else {
                kept.append(item)
            }
        }
        return kept
    }

    /// Removes near-duplicate strings from a list.
    /// Two strings are duplicates when their token overlap (Jaccard) ≥ 0.70.
    static func deduplicateStrings(_ items: [String]) -> [String] {
        var kept: [String] = []
        for item in items {
            let tokens = tokenSet(item)
            let isDup = kept.contains { jaccardSim(tokenSet($0), tokens) >= 0.70 }
            if !isDup { kept.append(item) }
        }
        return kept
    }

    // MARK: - Action Item Filtering

    /// Returns `true` when `task` has enough substance to be a real action item.
    ///
    /// Rejects tasks that are:
    ///   - Pure acknowledgements ("yeah", "right", "okay", "sounds good", etc.)
    ///   - Fewer than 3 meaningful words (words of ≥ 2 non-punctuation characters)
    ///
    /// Called from both the chunked path (`analyzeChunk`) and the single-call path
    /// (`MeetingIntelligenceService.analyzeSingleCall`) so the rule is applied once,
    /// in one place, for both pipelines.
    static func isMeaningfulActionItem(task: String) -> Bool {
        let normalized = task
            .lowercased()
            .trimmingCharacters(in: .init(charactersIn: ".,!? \t\n\r"))

        let acknowledgements: Set<String> = [
            "yeah", "yes", "no", "right", "okay", "ok", "yep", "nope",
            "sure", "got it", "sounds good", "mm-hmm", "mm hmm",
            "uh huh", "alright", "all right", "noted", "understood",
            "absolutely", "definitely", "of course", "will do",
            "thanks", "thank you", "correct", "exactly", "fair enough",
            "makes sense", "that makes sense"
        ]
        guard !acknowledgements.contains(normalized) else { return false }

        let words = normalized
            .components(separatedBy: .init(charactersIn: " .,;:!?-_\t\n\r"))
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count >= 2 }

        // Must have at least 4 meaningful words to constitute a real commitment
        guard words.count >= 4 else { return false }

        // Must contain an action verb — distinguishes real commitments from noun phrases,
        // discussion topics, and sentence fragments produced by keyword fallback.
        let actionVerbs: Set<String> = [
            // Base forms
            "set", "write", "send", "share", "call", "schedule", "review",
            "create", "build", "prepare", "update", "complete", "submit",
            "connect", "contact", "arrange", "book", "confirm", "check",
            "attend", "follow", "discuss", "present", "deliver", "provide",
            "define", "document", "test", "deploy", "fix", "implement",
            "coordinate", "ensure", "notify", "plan", "draft", "finalize", "finalise",
            "research", "investigate", "analyse", "analyze", "report",
            "handle", "manage", "make", "do", "get", "run", "add", "remove",
            "move", "merge", "push", "pull", "open", "close", "assign",
            "invite", "reach", "ask", "tell", "show", "verify",
            // Gerunds / present participles
            "setting", "writing", "sending", "sharing", "calling", "scheduling",
            "reviewing", "creating", "building", "preparing", "updating",
            "completing", "submitting", "connecting", "contacting", "arranging",
            "confirming", "checking", "attending", "following", "discussing",
            "presenting", "delivering", "providing", "defining", "documenting",
            "testing", "deploying", "fixing", "implementing", "coordinating",
            "ensuring", "notifying", "planning", "drafting", "finalizing", "finalising",
            "researching", "reporting", "handling", "managing", "making", "getting",
            "running", "adding", "removing", "moving", "merging", "pushing",
            "opening", "closing", "assigning", "inviting", "reaching", "verifying"
        ]
        return words.contains { actionVerbs.contains($0) }
    }

    // MARK: - Prompt Builders

    private static func buildExtractionPrompt(
        chunk: String,
        index: Int,
        total: Int,
        meetingType: String
    ) -> String {
        """
        Extract structured information from this \(meetingType) transcript segment.
        This is segment \(index + 1) of \(total). Extract only what is explicitly stated.

        TRANSCRIPT SEGMENT:
        \(chunk)

        Respond with EXACTLY these sections. Write "None" for empty sections.

        ## ACTION ITEMS
        Only output an action item when a speaker explicitly commits to a specific task, follow-up, or deliverable.
        Do NOT include acknowledgements (yeah, right, okay, sure), opinions, discussion topics, or unanswered questions.
        Write "None" if no explicit commitments exist.
        Format: OWNER: [name or Team] | TASK: [verb-first task] | PRIORITY: [High/Medium/Low] | DUE: [date or TBD]

        ## DECISIONS
        [- each decision made]

        ## OPEN QUESTIONS
        [- each unresolved question]

        ## RISKS
        [- each risk or concern]

        ## DEPENDENCIES
        [- each external dependency]

        ## COMMITMENTS
        [- each personal commitment made]

        ## KEY POINTS
        [1-3 bullet points capturing the main topics or outcomes of this segment]
        """
    }

    static func buildSynthesisPrompt(
        keyPointsText: String,
        decisionsCount: Int,
        actionsCount: Int,
        title: String
    ) -> String {
        """
        Write a factual summary for the meeting titled "\(title)".

        The meeting covered these topics:
        \(keyPointsText)

        There were \(decisionsCount) decision(s) and \(actionsCount) action item(s) identified.

        Rules:
        - Use ONLY the topics listed above. Do not add context not present in the list.
        - Do not infer roles, job titles, candidate qualities, or team dynamics.
        - Do not describe the meeting type or the participants' relationship.
        - Write 2-4 sentences. Be specific. No filler phrases.
        - Do NOT copy key-point text verbatim. Synthesize into cohesive sentences.
        - Do NOT begin with a speaker label such as "Me:" or "Participant:".
        - If the topic list is empty, write: Insufficient information for summary.
        """
    }

    // MARK: - Response Parser (same format as MeetingIntelligenceService)

    private static func parseChunkResponse(_ text: String) -> ChunkAnalysis {
        var analysis = ChunkAnalysis(index: 0)
        var currentSection = ""

        // Accumulator for phi3's multi-line action item format:
        //   Owners: x\nTask: y\nPriority: z | Due: TBD
        // Flushed whenever a new item starts or the section ends.
        var pendingOwner = "Team", pendingTask = "", pendingPriority = "Medium", pendingDue = ""

        func flushPendingItem() {
            guard !pendingTask.isEmpty else { return }
            let raw = "[\(pendingOwner)] \(pendingTask)"
            let item = ActionItemRecord(owner: pendingOwner, task: pendingTask,
                                        priority: pendingPriority, dueDateText: pendingDue,
                                        rawText: raw)
            analysis.structuredActionItems.append(item)
            analysis.actionItems.append(raw)
            pendingOwner = "Team"; pendingTask = ""; pendingPriority = "Medium"; pendingDue = ""
        }

        for line in text.components(separatedBy: "\n") {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)

            var content = s
            if let (section, inline) = chunkSectionHeader(from: s) {
                if currentSection == "actions" { flushPendingItem() }
                currentSection = section
                content = inline
            }

            guard !content.isEmpty, content != "None", content != "- None" else { continue }

            switch currentSection {
            case "actions":
                if content.contains("|") {
                    // Pipe-delimited single-line format: OWNER: x | TASK: y | PRIORITY: z | DUE: w
                    flushPendingItem()
                    if let item = parseActionItemLine(content) {
                        analysis.structuredActionItems.append(item)
                        analysis.actionItems.append("[\(item.owner)] \(item.task)")
                    }
                } else {
                    // Multi-line field format (phi3): Owners: / Task: / Priority: on separate lines
                    let kv = content.split(separator: ":", maxSplits: 1).map(String.init)
                    if kv.count == 2 {
                        let key = kv[0].trimmingCharacters(in: .whitespaces).uppercased()
                        let val = kv[1].trimmingCharacters(in: .whitespaces)
                        switch key {
                        case "OWNER", "OWNERS":
                            if !pendingTask.isEmpty { flushPendingItem() }
                            // Take first name when model writes "Me | Participant"
                            pendingOwner = val.components(separatedBy: "|").first?
                                .trimmingCharacters(in: .whitespaces) ?? "Team"
                            if pendingOwner.isEmpty { pendingOwner = "Team" }
                        case "TASK":
                            pendingTask = val
                        case "PRIORITY":
                            pendingPriority = val.components(separatedBy: CharacterSet.whitespaces)
                                .first?.capitalized ?? "Medium"
                        case "DUE":
                            pendingDue = (val.uppercased() == "TBD" || val.isEmpty) ? "" : val
                        default: break
                        }
                    }
                }
            case "decisions":
                for item in splitBulletLine(content) { analysis.decisions.append(item) }
            case "questions":
                for item in splitBulletLine(content) { analysis.openQuestions.append(item) }
            case "risks":
                for item in splitBulletLine(content) { analysis.risks.append(item) }
            case "dependencies":
                for item in splitBulletLine(content) { analysis.dependencies.append(item) }
            case "commitments":
                for item in splitBulletLine(content) { analysis.commitments.append(item) }
            case "keyPoints":
                let cleaned = content.hasPrefix("- ") ? String(content.dropFirst(2))
                    : (content.hasPrefix("• ") ? String(content.dropFirst(2)) : content)
                if !cleaned.isEmpty { analysis.keyPoints.append(cleaned) }
            default: break
            }
        }
        flushPendingItem()  // flush any trailing multi-line item
        return analysis
    }

    // MARK: - Section header detection

    /// Detects a section header in either of two formats phi3 uses:
    ///   Style 1 (markdown):  `## ACTION ITEMS` or `## Action Items:`
    ///   Style 2 (plain):     `ACTION ITEMS:` or `DECISIONS MADE`
    /// Returns `(sectionKey, inlineContent)` or nil if the line is not a header.
    private static func chunkSectionHeader(from line: String) -> (String, String)? {
        // Style 1: ## or ** prefix
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
            if let sec = sectionKey(for: name) { return (sec, inlinePart) }
        }

        // Style 2: plain uppercase title (phi3 style), with optional trailing colon
        // e.g. "ACTION ITEMS:", "DECISIONS MADE:", "KEY POINTS"
        // Exclude known per-item data fields so "TASK: do thing" isn't treated as a section.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: String
        var inlinePart = ""
        if let colonIdx = trimmed.firstIndex(of: ":") {
            candidate = String(trimmed[trimmed.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespaces).uppercased()
            inlinePart = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            candidate = trimmed.uppercased()
        }
        let dataFields: Set<String> = ["OWNER", "OWNERS", "TASK", "PRIORITY", "DUE"]
        guard !dataFields.contains(candidate) else { return nil }
        if let sec = sectionKey(for: candidate) { return (sec, inlinePart) }
        return nil
    }

    private static func sectionKey(for name: String) -> String? {
        if name.hasPrefix("ACTION ITEM") || name == "ACTIONS" { return "actions" }
        else if name.hasPrefix("DECISION")                    { return "decisions" }
        else if name.hasPrefix("OPEN Q")                      { return "questions" }
        else if name.hasPrefix("RISK")                        { return "risks" }
        else if name.hasPrefix("DEPEND")                      { return "dependencies" }
        else if name.hasPrefix("COMMIT")                      { return "commitments" }
        else if name.hasPrefix("KEY POINT")                   { return "keyPoints" }
        else { return nil }
    }

    private static func splitBulletLine(_ line: String) -> [String] {
        if !line.hasPrefix("- ") { return [line] }
        return line.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { part -> String? in
                guard !part.isEmpty, part != "None" else { return nil }
                return part.hasPrefix("- ") ? String(part.dropFirst(2)) : part
            }
    }

    private static func parseActionItemLine(_ line: String) -> ActionItemRecord? {
        let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        var owner = "Team", task = "", priority = "Medium", dueDate = ""
        for part in parts {
            let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key   = kv[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "OWNER":    owner    = value.isEmpty ? "Team" : value
            case "TASK":     task     = value
            case "PRIORITY": priority = value.capitalized
            case "DUE":      dueDate  = (value.uppercased() == "TBD" || value.isEmpty) ? "" : value
            default: break
            }
        }
        guard !task.isEmpty else { return nil }
        return ActionItemRecord(owner: owner, task: task, priority: priority,
                                dueDateText: dueDate, rawText: line)
    }

    // MARK: - Keyword Fallback

    private static func keywordChunkFallback(_ chunk: String, index: Int) -> ChunkAnalysis {
        var analysis = ChunkAnalysis(index: index)
        let lines = chunk.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        func matching(_ kws: [String]) -> [String] {
            Array(
                lines
                    .filter { l in let lo = l.lowercased(); return kws.contains { lo.contains($0) } }
                    .map { MeetingIntelligenceService.cleanTranscriptLine($0) }
                    .filter { !$0.isEmpty }
                    .prefix(4)
            )
        }
        analysis.decisions   = matching(["decided", "agreed", "approved"])
        analysis.commitments = matching(["i will", "i'll", "will send", "will prepare"])
        analysis.actionItems = matching(["action", "todo", "next step", "follow up"])
        analysis.keyPoints   = Array(lines.prefix(2).map { MeetingIntelligenceService.cleanTranscriptLine($0) }.filter { !$0.isEmpty })
        return analysis
    }

    private static func keyPointsSummary(from chunks: [ChunkAnalysis]) -> String {
        let points = chunks.sorted { $0.index < $1.index }
            .flatMap(\.keyPoints)
            .map { MeetingIntelligenceService.cleanTranscriptLine($0) }
            .filter { !$0.isEmpty }
            .prefix(6)
        guard !points.isEmpty else { return "" }
        return points.joined(separator: ". ")
    }

    // MARK: - Private helpers

    private static func trailingLines(of lines: [String], targetChars: Int) -> [String] {
        var result: [String] = []
        var total = 0
        for line in lines.reversed() {
            total += line.count + 1
            result.insert(line, at: 0)
            if total >= targetChars { break }
        }
        return result
    }

    private static func isDuplicateAction(_ a: ActionItemRecord, _ b: ActionItemRecord) -> Bool {
        let ownerMatch = a.owner.lowercased() == b.owner.lowercased()
            || a.owner == "Team" || b.owner == "Team"
        let taskSim    = jaccardSim(tokenSet(a.task), tokenSet(b.task))
        return ownerMatch && taskSim >= 0.60
    }

    private static func detailScore(_ item: ActionItemRecord) -> Int {
        (item.dueDateText.isEmpty ? 0 : 1) + (item.owner.lowercased() == "team" ? 0 : 2)
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: .init(charactersIn: " .,;:!?-_"))
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count >= 3 })
    }

    private static func jaccardSim(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1.0 }
        guard !a.isEmpty, !b.isEmpty  else { return 0.0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}
