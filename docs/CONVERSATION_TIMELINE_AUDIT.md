# Conversation Timeline Architecture Audit

**Date:** 2026-05-31

---

## Problem: Source-Channel Transcript

The previous architecture stored two large text blocks:

```
Me: Hello everyone let's get started. Today we need to discuss the Q3 budget. 
There are three main items. First the marketing spend. Second the engineering 
headcount. [... 30 minutes of continuous speech ...]

Participant: Thanks for setting this up. Our main concern is the headcount 
increase. We saw last quarter that it was not sustainable. [... 30 minutes ...]
```

**Issues:**
1. Conversation flow is lost — the user cannot read who said what when
2. Both blocks are the same length for equal-speech meetings → unreadable wall of text
3. AI analysis sees two monolithic blocks, not a dialogue
4. No timestamps on individual utterances
5. Not extensible to multiple speakers (diarization would only add more big blocks)

---

## New Architecture: Conversation Timeline

### Data Layers

| Layer | Model | Purpose | Written | Removed |
|---|---|---|---|---|
| **Recovery** | `TranscriptChunk` | Crash-safe full-text backup | Every ≥10-char update during recording | Never (retained for recovery) |
| **Timeline** | `TranscriptSegment` | Conversation display + AI analysis | At finalize (from chunks) | Future: with meeting |
| **Legacy** | `MeetingItem.transcript` | Backward compat + orphan recovery | Checkpoint every 3s + finalize | Never |

### TranscriptChunk → TranscriptSegment Pipeline

```
Recording session active
  ↓ (every 10-char growth)
TranscriptChunk (full accumulated text per speaker)
                         ↓
              Recording stops
                         ↓
          transcriptStore.finalize()
                         ↓
    buildTimelineSegments(for:context:)
                         ↓
    FetchDescriptor<TranscriptChunk> (all chunks for this meeting)
                         ↓
    ConversationTimelineBuilder.buildSegments(from:meetingId:)
      1. Separate by speaker ("mic" / "participant")
      2. Sort each group by timestamp
      3. Compute DELTA text between consecutive chunks
      4. Create TranscriptSegment per meaningful delta
                         ↓
    ConversationTimelineBuilder.mergeConsecutive(_:windowSeconds: 20)
      • Merge same-speaker segments within 20-second window
      • Flush when speaker switches or window exceeded
                         ↓
    context.insert(segment) × N → context.save()
                         ↓
    MeetingItem (segments available for display + analysis)
```

### Result: Conversation Timeline

```
[00:02] Me: Hello everyone let's get started
[00:08] Participant: Good morning thanks for the invite
[00:20] Me: Today we need to discuss the Q3 budget
[00:45] Participant: Our main concern is headcount
[01:03] Me: Right I understand let me share my screen
[01:22] Participant: I can see it now
```

---

## Model Audit

### TranscriptSegment Fields

| Field | Type | Purpose | Extensibility |
|---|---|---|---|
| `id` | UUID | Stable identity | — |
| `meetingId` | UUID | Link to meeting | — |
| `timestamp` | Date | Wall-clock time (for ordering + display offset) | — |
| `source` | String | Physical audio origin: "mic" or "participant" | Future: "screen_share", "phone_call" |
| `speakerLabel` | String | Human-readable label: "Me", "Participant" | Future diarization updates this to "Speaker 1" etc. |
| `text` | String | Delta transcript text (no speaker prefix) | — |
| `sequenceIndex` | Int | Tie-break ordering at same timestamp | — |

**`source` vs. `speakerLabel`**: These are deliberately separate.
- `source` = physical fact (which audio channel). Never changes after creation.
- `speakerLabel` = logical interpretation. Can be updated by `SpeakerIdentificationProvider` without changing the underlying data.

### TranscriptChunk Fields (unchanged, still recovery layer)

| Field | Type | Purpose |
|---|---|---|
| `id` | UUID | Stable identity |
| `meetingId` | UUID | Link to meeting |
| `timestamp` | Date | Wall-clock time chunk was written |
| `speaker` | String | "mic" or "participant" |
| `text` | String | Full accumulated labeled transcript at this point |

---

## Component Interactions

```
TranscriptStore.updateMic()
    ↓ (every ≥10-char growth, real-time)
TranscriptChunk [speaker="mic", text="Me: [full text]"]

TranscriptStore.updateParticipant()
    ↓ (every ≥10-char growth, real-time)
TranscriptChunk [speaker="participant", text="Participant: [full text]"]

TranscriptStore.finalize()
    ↓ (after recording stops)
  → MeetingItem.transcript = best-of-N merged text (backward compat)
  → buildTimelineSegments():
        Fetch TranscriptChunks for meeting
        ConversationTimelineBuilder.buildSegments() → raw segments
        ConversationTimelineBuilder.mergeConsecutive() → readable blocks
        Insert TranscriptSegments → SwiftData

MeetingDetailView
    ↓ (on appear)
  TranscriptViewMode picker: [Timeline | Full Transcript]
  • Timeline mode  → ConversationTimelineView(segments:meetingStart:)
  • Legacy mode    → TextEditor(meeting.transcript)
  • Default: Timeline if segments exist, Legacy if not

MeetingIntelligenceService.analyze(title:segments:meetingStart:fallback:)
    ↓
  ConversationTimelineBuilder.formatted(segments:meetingStart:)
    → "[00:02] Me: Hello everyone...\n[00:08] Participant: Good morning..."
    → passed to AI for richer contextual analysis
```

---

## Backward Compatibility

| Scenario | Behavior |
|---|---|
| Meeting recorded before timeline feature | `segments = []` → MeetingDetailView shows legacy view |
| Meeting with only mic (no system audio) | Segments from mic chunks only → "Me:" blocks only |
| No TranscriptChunks (very short/corrupt recording) | `buildTimelineSegments` no-ops → no segments → legacy view |
| Export (JSON/MD/TXT/CSV/ZIP) | Uses `MeetingItem.transcript` (unchanged) |
| Orphan recovery after crash | Still uses UserDefaults + TranscriptChunks (unchanged) |

---

## Granularity Analysis

| Meeting length | Chunks generated | Raw segments | After 20s merge |
|---|---|---|---|
| 5 minutes | ~325 (mic + participant) | ~325 | ~15–30 |
| 15 minutes | ~975 | ~975 | ~45–90 |
| 30 minutes | ~1,950 | ~1,950 | ~90–180 |
| 60 minutes | ~3,900 | ~3,900 | ~180–360 |

Post-merge, 180–360 segments for a 60-minute meeting = ~3–6 turns per minute. Readable.

---

## AI Analysis Impact

**Before (flat merged string):**
```
Me: [30 minutes of mic speech]

Participant: [30 minutes of system audio]
```

**After (conversation timeline string):**
```
[00:00] Me: Hello everyone let's discuss the Q3 budget
[00:45] Participant: Our main concern is headcount
[01:03] Me: Right let me share the numbers
...
```

The formatted timeline gives the AI:
- Turn-by-turn attribution
- Temporal context (questions followed by answers)
- Better extraction of decisions ("we decided" in response to a proposal)
- Better commitment extraction ("I will" attributed to the right speaker)
