# AI Analysis Pipeline Audit

**Date:** 2026-05-31

---

## Pre-Upgrade Pipeline

```
Transcript string
    ↓
aiService.generateSummary(for: transcript)
    │  Prompt: "Summarize this meeting transcript accurately.
    │           Focus on decisions made, commitments given,
    │           and next actions required:\n\n{transcript}"
    │  Max tokens: 512
    │
    ├─ Summary: AI response OR first 3 sentences (fallback)
    │
    └─ Keyword extraction (no AI):
         decisions   → lines containing "decided", "decision", "agreed", "approved"
         commitments → lines containing "i will", "i'll", "we will", ...
         actionItems → lines containing "action", "todo", "to do", "next step", ...
         (each capped at 8 items)
```

**Critical issues:**
1. Single 7-word prompt with no meeting context
2. All extraction (decisions/actions/commitments) is pure keyword matching
3. 512 max tokens limits summary quality
4. No meeting type detection — identical prompt for standup and executive review
5. No structured data — no owner/priority/due date on action items
6. No open questions, risks, or dependencies extracted
7. `AIService.generateSummary` wraps all calls in the same `summaryPrompt()` — no generic prompt method

---

## Post-Upgrade Pipeline

```
Transcript string + title
    ↓
Step 1: Meeting type detection (LOCAL — no AI, synchronous)
    │  Keyword signals in title + first 2000 chars of transcript
    │  Returns: MeetingType.rawValue (e.g. "Standup", "Sales Call")
    │
    ↓
Step 2: Comprehensive structured prompt (1 AI call, 1500 max tokens)
    │
    │  MEETING TITLE: {title}
    │  MEETING TYPE: {type}
    │  {type-specific context instructions}
    │
    │  TRANSCRIPT:
    │  {first 6000 chars}
    │
    │  Respond with:
    │  ## SUMMARY      → 3-5 sentences, type-focused
    │  ## ACTION ITEMS → OWNER|TASK|PRIORITY|DUE per line
    │  ## DECISIONS    → bullet list
    │  ## OPEN QUESTIONS → bullet list
    │  ## RISKS        → bullet list
    │  ## DEPENDENCIES → bullet list
    │  ## COMMITMENTS  → bullet list
    │
    ↓
Step 3: Response parser
    │  Extracts each section by "## HEADER" markers
    │  Parses action items by pipe-separated key:value pairs
    │
    ↓
Step 4: Keyword fallback (when AI fails or response unparseable)
    │  Fills empty sections with keyword extraction
    │
    ↓
MeetingAnalysis {
    summary, meetingType,
    decisions, openQuestions, risks, dependencies,
    commitments, actionItems,
    structuredActionItems: [ActionItemRecord],
    suggestedTasks
}
```

---

## AIService Changes

### Added: `generate(prompt:maxTokens:)` — generic prompt method

Sends `prompt` directly to providers without wrapping in `summaryPrompt()`. Used by `MeetingIntelligenceService` for full control over the prompt.

```swift
func generate(prompt: String, maxTokens: Int = 1500) async -> (text: String, fallbackUsed: Bool)
```

### Changed: Provider methods refactored

All provider-specific methods (`callOllama`, `callOpenAI`, `callAnthropic`, `callGemini`) now accept a `prompt: String` and `maxTokens: Int` parameter directly. The old `generateOllamaSummary(transcript:)` etc. are removed; `generateSummary` now delegates to `generate`.

### Max tokens increased

- `generateSummary` (legacy): 512 tokens
- `generate` (comprehensive analysis): 1500 tokens default

---

## Data Flow to `MeetingItem`

```swift
// Old
meeting.summary     = analysis.summary
meeting.decisions   = analysis.decisions
meeting.actionItems = analysis.actionItems
meeting.commitments = [...]

// New (additive — no breaking changes)
meeting.summary               = analysis.summary
meeting.meetingType           = analysis.meetingType        // NEW
meeting.decisions             = analysis.decisions
meeting.openQuestions         = analysis.openQuestions      // NEW
meeting.risks                 = analysis.risks              // NEW
meeting.dependencies          = analysis.dependencies       // NEW
meeting.actionItems           = analysis.actionItems        // flat (backward compat)
meeting.structuredActionItemsJSON = JSON([ActionItemRecord]) // NEW
meeting.commitments           = [CommitmentItem...]
```

---

## Folder Intelligence Upgrade

`FolderSummaryService` now also extracts:
- `recurringBlockers` — from `risks` + `openQuestions` across meetings
- `recurringRisks` — from `risks` fields across meetings

`FolderSummaryItem` schema updated with `recurringBlockers: [String]` and `recurringRisks: [String]`.

---

## Backward Compatibility

All new `MeetingItem` fields have defaults (`""` or `[]` or `nil`). Existing meetings display normally — new sections are empty until re-analyzed. No schema migration required (SwiftData handles new optional/defaulted fields via the existing recovery path).
