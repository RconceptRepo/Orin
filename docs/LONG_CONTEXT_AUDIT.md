# Long Context Audit

**Date:** 2026-05-31

---

## Pre-Upgrade Truncation Points

| Location | Limit | Effect |
|---|---|---|
| `MeetingIntelligenceService.buildComprehensivePrompt()` | 6,000 chars | Transcript truncated at ~9 minutes of speech |
| `MeetingIntelligenceService.detectMeetingType()` | 2,000 chars | Type detection reads only first 3 minutes |
| `AIService.generate()` default max tokens | 1,500 | Response capped; structured sections may be cut |
| `AIService.generateSummary()` max tokens | 512 | Very short summaries |
| `FolderSummaryService.maxMeetingsForAI` | 10 meetings | Cap on folder intelligence input |
| `FolderSummaryService.decisions.prefix(3)` | 3 per meeting | Majority of decisions hidden |
| `FolderSummaryService.allDecisions.prefix(20)` | 20 total | All-decisions section capped |
| `MeetingIntelligenceService.extractLines(prefix:)` | 8 items | Keyword extraction capped at 8 |
| `buildSuggestedTasks(prefix:)` | 6 tasks | Suggested tasks capped |

---

## Meeting Length → Characters

At 130 words/min average speech rate, 5 chars/word:

| Duration | Characters | Old limit | Covered |
|---|---|---|---|
| 15 minutes | ~9,750 | 6,000 | **61%** — loses last 6 minutes |
| 30 minutes | ~19,500 | 6,000 | **31%** — loses last 21 minutes |
| 60 minutes | ~39,000 | 6,000 | **15%** — loses last 51 minutes |
| 90 minutes | ~58,500 | 6,000 | **10%** — loses last 81 minutes |
| 120 minutes | ~78,000 | 6,000 | **8%** — loses last 110 minutes |

**Critical finding:** Action items and decisions are typically discussed in the LAST 25% of a meeting (during wrap-up). The old 6,000-char limit meant these were almost never captured for meetings longer than 9 minutes.

---

## Provider Context Windows

| Provider | Context limit | Max transcript (at 4 chars/token) |
|---|---|---|
| Ollama llama3 | 8,192 tokens | ~32,768 chars ≈ 50 min |
| GPT-4o-mini | 128,000 tokens | ~512,000 chars ≈ 13+ hours |
| Claude Haiku 4.5 | 200,000 tokens | ~800,000 chars ≈ 20+ hours |
| Gemini 1.5 Flash | 1,000,000 tokens | effectively unlimited |

Ollama is the primary/default provider (local, free, preferred). Chunked analysis is designed to stay within Ollama's 8,192-token context: each chunk (5,000 chars) plus prompt overhead (~500 tokens) fits in ~1,750 tokens — well within the limit.

---

## Post-Upgrade Thresholds

| Parameter | Value | Covers |
|---|---|---|
| `singleCallThreshold` | 12,000 chars | ~18 min (full prompt fits all providers) |
| `chunkSize` | 5,000 chars | ~7-8 min per chunk |
| `overlapSize` | 500 chars | ~45 sec context bridge between chunks |
| Extraction max tokens | 800 | Action items + decisions + key points per chunk |
| Synthesis max tokens | 600 | Final executive summary |

---

## Token Budget Per Chunk Call (Ollama)

```
Extraction prompt overhead:  ~500 tokens
Transcript chunk (5000 chars): ~1,250 tokens
Total input:  ~1,750 tokens  (21% of 8,192 limit)
Response cap:  800 tokens
Total per call:  ~2,550 tokens  (31% of 8,192 limit)
```

Comfortable margin — no risk of context overflow.

---

## API Call Count by Meeting Length

| Duration | Chars | Chunks | Extraction calls | Synthesis | Total calls |
|---|---|---|---|---|---|
| < 18 min | ≤ 12,000 | 1 (single) | 0 | 0 | **1** |
| 30 min | ~19,500 | 4 | 4 | 1 | **5** |
| 60 min | ~39,000 | 8 | 8 | 1 | **9** |
| 90 min | ~58,500 | 12 | 12 | 1 | **13** |
| 120 min | ~78,000 | 16 | 16 | 1 | **17** |

At 2-3 seconds per Ollama call (M-series Mac), a 120-minute meeting takes ~34-51 seconds for full analysis. This runs as a background task — the user is not blocked.

---

## MeetingKnowledgeSnapshot Token Efficiency

For folder intelligence, the snapshot replaces full meeting summaries:

| Approach | Tokens per meeting | 10 meetings | 20 meetings |
|---|---|---|---|
| Raw transcript | ~10,000 | 100,000 (exceeds GPT limit) | impossible |
| Full summary + fields | ~500-1,000 | 5,000-10,000 | 10,000-20,000 |
| MeetingKnowledgeSnapshot | ~150-300 | 1,500-3,000 | 3,000-6,000 |

Snapshots are **3-7× more token-efficient** than building from individual fields, and **30-100× more efficient** than including raw transcripts.
