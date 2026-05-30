# Folder Intelligence Report

**Date:** 2026-05-31

---

## Overview

`FolderSummaryService` generates cross-meeting intelligence for a `MeetingFolderItem` using all meetings in that folder as input. The results are persisted in `FolderSummaryItem` (one per folder) and displayed in `FolderDetailView → Intelligence tab`.

---

## Input

All `MeetingItem` records with `folderID == folder.id`, including:
- `title`, `date`
- `summary` (from AI analysis or empty)
- `decisions`
- `actionItems`
- `transcript` (not used directly — too large)

For the AI prompt, the 10 most recent meetings are used (configurable via `maxMeetingsForAI`). All meetings are used for keyword-extraction-based signals (recurring decisions/actions/topics).

---

## Outputs

### 1. `overallSummary` — AI-generated

Prompt structure:
```
MEETING FOLDER: {name} ({N} meetings)

=== MEETING SUMMARIES ===
{date}: {title}
{summary}
Decisions: {decisions}

[...repeats for each meeting...]

=== ALL DECISIONS ===
• {decision 1}
• {decision 2}

=== ALL ACTION ITEMS ===
• {action 1}

Based on these N meetings, write a concise paragraph (3-5 sentences)
summarising the recurring themes, ongoing progress, and key patterns.
```

**AI provider fallback chain:** Ollama → OpenAI → Claude → Gemini (same as `MeetingIntelligenceService`)

**Fallback (all AI unavailable):** First 3 meeting summaries concatenated.

---

### 2. `recurringDecisions` — keyword-based

Algorithm:
- Collect all `decisions` from all meetings in the folder
- Group by normalized (trimmed, lowercased) text
- Return items appearing in ≥ `max(2, meetingCount/3)` meetings
- Sorted by frequency, capped at 6

Example (5 meetings):
```
"Approved roadmap for Q3"   → appeared in 3 meetings → included
"Use TypeScript for backend" → appeared in 4 meetings → included
"Hire 2 engineers by June"   → appeared in 1 meeting  → excluded
```

---

### 3. `recurringActionItems` — same algorithm as decisions

---

### 4. `recurringTopics` — keyword frequency

Algorithm:
- Collect all text from summaries, decisions, and action items
- Tokenize: lowercase, split, filter length ≥ 4, remove stop words
- Count frequency across all text
- Return top 8 by frequency, filter tokens appearing ≥ 2 times
- Capitalize for display

Example output for an engineering sync folder:
`["Deployment", "Testing", "Refactor", "Performance", "Roadmap", "Sprint", "Metrics", "Review"]`

---

## FolderSummaryItem Schema

```swift
@Model final class FolderSummaryItem {
    var id: UUID
    var folderID: UUID
    var overallSummary: String
    var recurringDecisions: [String]
    var recurringActionItems: [String]
    var recurringTopics: [String]
    var meetingCount: Int
    var generatedAt: Date
}
```

One `FolderSummaryItem` per folder. Each "Regenerate" call inserts a new record; the view displays the most recently generated item (`max(by: generatedAt)`). Old records are not automatically pruned (low storage impact: ~1-5 KB per summary).

---

## FolderDetailView — Intelligence Tab

When `FolderSummaryItem` exists:
- **Overall Summary card** — AI-generated paragraph + generation date
- **Recurring Topics card** — tag chips (FlowTagView)
- **Recurring Decisions card** — InsightCard list
- **Recurring Action Items card** — InsightCard list
- **Regenerate button** — re-runs the full analysis

When no `FolderSummaryItem` exists:
- Call-to-action card with "Generate Summary" button
- Disabled when folder has no meetings

---

## Limitations and Known Constraints

| Limitation | Impact |
|---|---|
| AI prompt limited to 10 most recent meetings | Folders with 50+ meetings: older context not summarized |
| Keyword extraction is lexical, not semantic | "Refactor" and "Refactoring" are different tokens |
| Recurring items need exact string match | Paraphrased decisions not grouped |
| One FolderSummaryItem per generation | Old summaries accumulate (manual cleanup not yet implemented) |
| Token limits for AI: ~10,000 chars per prompt | Well within typical model context windows |

---

## User Flow

```
User opens Meetings view
  → Selects a folder name (not expand toggle)
  → Right panel shows FolderDetailView
      → "Meetings" tab: list of all meetings in folder
      → "Intelligence" tab:
          → If summary exists: summary + topics + decisions + actions
          → If no summary: "Generate Summary" button
  → Taps "Generate Summary"
      → FolderSummaryService.generate() async
      → AI prompt with all meeting data
      → FolderSummaryItem inserted to SwiftData
      → Intelligence tab refreshes
```
