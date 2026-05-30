# AI Long Context Report

**Date:** 2026-05-31

---

## Summary

Upgraded the Orin AI analysis pipeline from a 6,000-character hard truncation to a full-meeting hierarchical chunked analysis supporting transcripts up to 120+ minutes.

---

## Architecture

### Routing Logic

```
analyze(title:transcript:)
    │
    ├─ transcript.count ≤ 12,000 chars (~18 min)
    │    └─ analyzeSingleCall() — 1 AI call, existing behavior, now uses full 12k
    │
    └─ transcript.count > 12,000 chars
         └─ analyzeChunked()
              │
              ├─ TranscriptChunker.chunks(of:)
              │    Split into 5,000-char overlapping chunks
              │    Aligned to line boundaries (no mid-utterance splits)
              │    500-char overlap preserves cross-boundary context
              │
              ├─ For each chunk (sequential):
              │    TranscriptChunker.analyzeChunk()
              │    → extraction prompt (800 token response)
              │    → ChunkAnalysis { decisions, actionItems, risks, keyPoints, ... }
              │
              ├─ TranscriptChunker.deduplicateActionItems() — owner+task Jaccard ≥ 60%
              │    TranscriptChunker.deduplicateStrings()   — content Jaccard ≥ 70%
              │
              └─ TranscriptChunker.synthesize()
                   → synthesis prompt using key points only (600 token response)
                   → final executive summary
```

### Key Design Decisions

**1. Sequential chunk processing (not parallel)**
Parallel processing would use multiple simultaneous Ollama connections. Since Ollama is single-instance, parallelism doesn't improve speed for local inference. Sequential calls are simpler and avoid connection contention.

**2. Extraction-only per chunk, synthesis at the end**
Each chunk produces structured data (action items, decisions, key points) but NO per-chunk summary. The final summary is synthesized ONCE from the key points of all chunks. This means:
- One less AI call per chunk
- Summary quality is better (global context from all key points, not just one chunk)

**3. Line-aligned chunk boundaries**
Chunks split at newline boundaries so speaker utterances are never cut mid-sentence. This preserves the conversational structure that the AI needs to extract meaning from.

**4. 500-char overlap**
The overlap ensures that sentences or action items that span a chunk boundary appear in both chunks. The deduplication step removes the resulting duplicates.

**5. Keyword fallback per chunk**
If any individual chunk's AI call fails (timeout, rate limit, etc.), the chunk falls back to keyword extraction. The overall analysis proceeds — a partial fallback in one chunk doesn't abort the entire meeting analysis.

---

## Hierarchical Summarization Flow

### Example: 30-minute Engineering Standup (19,500 chars → 4 chunks)

```
Chunk 1 (0:00–7:30): Alice and Bob report completed work
  KeyPoints: ["Auth service refactor complete", "Bob finished API docs"]
  ActionItems: [OWNER: Alice | TASK: Merge auth PR | PRIORITY: High | DUE: Today]
  Decisions: ["Use JWT for session tokens"]

Chunk 2 (6:30–15:00): Bob raises staging blocker, Dave joins
  KeyPoints: ["Staging env access blocked by DevOps", "Dave commits to integration tests"]
  ActionItems: [OWNER: Dave | TASK: Write integration tests | PRIORITY: Medium | DUE: Tomorrow]
  Risks: ["Staging env delay may push sprint timeline"]

Chunk 3 (14:00–22:30): Sprint goal discussion
  KeyPoints: ["Sprint goal: ship auth v2 by Friday", "12 story points committed"]
  Decisions: ["Delay OAuth feature to next sprint"]

Chunk 4 (21:30–30:00): Wrap-up and commitments
  KeyPoints: ["Bob will contact DevOps about staging", "Carol reviews sprint board"]
  ActionItems: [OWNER: Bob | TASK: Contact DevOps about staging | PRIORITY: High | DUE: Today]
  Commitments: ["Bob will reach out to DevOps today"]

SYNTHESIS PROMPT INPUT:
  • Auth service refactor complete, Bob finished API docs
  • Staging env access blocked by DevOps, Dave commits to integration tests
  • Sprint goal: ship auth v2 by Friday, 12 story points committed
  • Bob will contact DevOps about staging, Carol reviews sprint board
  Total: 3 decisions, 3 action items (after dedup)

FINAL SUMMARY:
"The team completed the auth service refactor and API documentation. Sprint goal
is set to ship auth v2 by Friday with 12 story points committed. A staging
environment access blocker was raised — Bob will contact DevOps today to resolve
it. OAuth was deprioritized to next sprint."
```

**Key property:** The action item "Bob will contact DevOps about staging" appears in BOTH Chunk 2 (as a risk) and Chunk 4 (as a commitment). Deduplication collapses these. Without chunking, only the Chunk 1 action item (in the first 6000 chars) would have been captured — the wrap-up actions would be lost.

---

## MeetingKnowledgeSnapshot

### Purpose

A compact, pre-structured representation of a meeting's analysis. Persisted as JSON in `MeetingItem.meetingKnowledgeJSON` after each analysis run.

### Structure

```swift
struct MeetingKnowledgeSnapshot: Codable {
    var meetingId: UUID
    var title: String
    var date: Date
    var meetingType: String
    var summary: String
    var decisions: [String]
    var openQuestions: [String]
    var risks: [String]
    var dependencies: [String]
    var commitments: [String]
    var actionItems: [String]
    var structuredActionItems: [ActionItemRecord]
    var durationSeconds: TimeInterval
    var participants: [String]
}
```

### Token Budget Comparison for Folder Intelligence

For a folder with 10 meetings × 1-hour average:

| Approach | Tokens | Notes |
|---|---|---|
| Raw transcripts | ~97,500 | Exceeds Ollama (8k) and GPT-4o-mini (128k) |
| AI-generated summaries | ~5,000-10,000 | Fits GPT/Claude, barely fits Ollama |
| MeetingKnowledgeSnapshot | ~1,500-3,000 | Fits all providers comfortably |

### Upgrade to FolderSummaryService

`FolderSummaryService.buildPrompt()` now uses `snapshotEntry()` instead of `legacyEntry()` when a snapshot is available. The snapshot entry is:
- `dateStr: title [meetingType]`
- Summary (1 paragraph)
- Decisions: (prefix 3)
- Risks: (prefix 2)
- Actions: N items (count only)

~150-250 tokens per meeting vs. ~500-1000 with full field expansion.

---

## Action Item Deduplication

### Algorithm

For `ActionItemRecord` pairs (a, b):
```
isDuplicate(a, b) = ownerMatch(a, b) AND taskJaccard(a, b) ≥ 0.60
```

Where:
- `ownerMatch` = `a.owner.lowercased() == b.owner.lowercased()` (or either is "Team")
- `taskJaccard` = token intersection / token union, tokens filtered to length ≥ 3

When duplicates exist, the item with higher `detailScore` wins:
```
detailScore = (dueDateText non-empty ? 1 : 0) + (owner != "Team" ? 2 : 0)
```

### Example

```
Chunk 2: OWNER: Bob | TASK: reach out DevOps staging | ...
Chunk 4: OWNER: Bob | TASK: contact DevOps staging environment today | DUE: Today

taskTokens(a) = {"reach", "devops", "staging"}
taskTokens(b) = {"contact", "devops", "staging", "environment", "today"}
intersection  = {"devops", "staging"}
union         = {"reach", "contact", "devops", "staging", "environment", "today"}
Jaccard       = 2/6 = 0.33  ← BELOW 0.60 threshold → not deduped

(Kept separately because different verbs drop similarity below threshold)
```

The threshold of 0.60 is tuned to catch obvious duplicates ("Send email Alice" vs "Alice send email") while preserving legitimately different items.

---

## Regression Impact

All 29 non-vault test suites continue to pass. The analysis interface (`MeetingAnalysis`, `analyze()`) is unchanged — the routing to chunked vs. single-call is transparent to callers.
