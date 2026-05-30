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
        let result = await aiService.generate(prompt: prompt, maxTokens: 800)

        if result.fallbackUsed || result.text.isEmpty {
            log.warning("chunk \(index + 1)/\(totalChunks): AI unavailable — using keyword fallback")
            return keywordChunkFallback(chunk, index: index)
        }

        var analysis = parseChunkResponse(result.text)
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
            title: title,
            meetingType: meetingType
        )

        let result = await aiService.generate(prompt: prompt, maxTokens: 600)
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
        [OWNER: [name or Team] | TASK: [imperative description] | PRIORITY: [High/Medium/Low] | DUE: [date or TBD]]

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

    private static func buildSynthesisPrompt(
        keyPointsText: String,
        decisionsCount: Int,
        actionsCount: Int,
        title: String,
        meetingType: String
    ) -> String {
        """
        Write an executive summary for this \(meetingType): "\(title)"

        The meeting covered the following topics:
        \(keyPointsText)

        Total outcomes across the meeting:
        - Decisions made: \(decisionsCount)
        - Action items assigned: \(actionsCount)

        \(MeetingIntelligenceService.typeSpecificContext(for: meetingType))

        Write a 3-5 sentence executive summary. Be specific. No filler phrases like
        "the team discussed" or "various topics were covered."
        """
    }

    // MARK: - Response Parser (same format as MeetingIntelligenceService)

    private static func parseChunkResponse(_ text: String) -> ChunkAnalysis {
        var analysis = ChunkAnalysis(index: 0)
        var currentSection = ""

        for line in text.components(separatedBy: "\n") {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("## ACTION ITEMS")  { currentSection = "actions";      continue }
            if s.hasPrefix("## DECISIONS")     { currentSection = "decisions";    continue }
            if s.hasPrefix("## OPEN QUESTIONS"){ currentSection = "questions";    continue }
            if s.hasPrefix("## RISKS")         { currentSection = "risks";        continue }
            if s.hasPrefix("## DEPENDENCIES")  { currentSection = "dependencies"; continue }
            if s.hasPrefix("## COMMITMENTS")   { currentSection = "commitments";  continue }
            if s.hasPrefix("## KEY POINTS")    { currentSection = "keyPoints";    continue }

            guard !s.isEmpty, s != "None", s != "- None" else { continue }

            switch currentSection {
            case "actions":
                if let item = parseActionItemLine(s) {
                    analysis.structuredActionItems.append(item)
                    analysis.actionItems.append("[\(item.owner)] \(item.task)")
                }
            case "decisions":
                analysis.decisions.append(s.hasPrefix("- ") ? String(s.dropFirst(2)) : s)
            case "questions":
                analysis.openQuestions.append(s.hasPrefix("- ") ? String(s.dropFirst(2)) : s)
            case "risks":
                analysis.risks.append(s.hasPrefix("- ") ? String(s.dropFirst(2)) : s)
            case "dependencies":
                analysis.dependencies.append(s.hasPrefix("- ") ? String(s.dropFirst(2)) : s)
            case "commitments":
                analysis.commitments.append(s.hasPrefix("- ") ? String(s.dropFirst(2)) : s)
            case "keyPoints":
                let cleaned = s.hasPrefix("- ") ? String(s.dropFirst(2))
                    : (s.hasPrefix("• ") ? String(s.dropFirst(2)) : s)
                if !cleaned.isEmpty { analysis.keyPoints.append(cleaned) }
            default: break
            }
        }
        return analysis
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
            Array(lines.filter { l in let lo = l.lowercased(); return kws.contains { lo.contains($0) } }.prefix(4))
        }
        analysis.decisions  = matching(["decided", "agreed", "approved"])
        analysis.commitments = matching(["i will", "i'll", "will send", "will prepare"])
        analysis.actionItems = matching(["action", "todo", "next step", "follow up"])
        analysis.keyPoints  = Array(lines.prefix(2))
        return analysis
    }

    private static func keyPointsSummary(from chunks: [ChunkAnalysis]) -> String {
        let points = chunks.sorted { $0.index < $1.index }.flatMap(\.keyPoints).prefix(6)
        return points.joined(separator: " ")
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
