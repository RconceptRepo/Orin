# Transcript Pipeline Audit

**Date:** 2026-05-30

---

## Pipeline Overview

```
Microphone (AVAudioEngine input node)
    │
    ├─► AVAudioFile (.caf) — raw audio on disk
    │
    └─► SFSpeechAudioBufferRecognitionRequest
            │
            ▼ (partial results every ~0.5–2 s)
        RecordingService.transcript  ("hello world…")
        RecordingService.speakerTranscript ("Me: hello world…")
            │
            ▼ (via MainContainerView / MeetingDetailView onChange)
        TranscriptStore.updateMic(labeled)
            │

System Audio (ScreenCaptureKit SCStream)
    │
    └─► CMSampleBuffer → AVAudioPCMBuffer
            │
            ▼ (real-time feed)
        SFSpeechAudioBufferRecognitionRequest (parallel instance)
            │
            ▼ (partial results)
        SystemAudioCaptureService.transcript ("other speaker text")
        SystemAudioCaptureService.participantSpeakerTranscript ("Participant: …")
            │
            ▼ (via MainContainerView / MeetingDetailView onChange)
        TranscriptStore.updateParticipant(labeled)
            │

TranscriptStore
    │  mergeTranscripts(mic, participant) → liveTranscript
    │  checkpoint() every 3 s → MeetingItem.transcript (SwiftData)
    │  UserDefaults backup every checkpoint (crash safety)
    │  finalize() after stop → best-of-N selection, integrity check
    ▼

MeetingItem.transcript (SwiftData / SQLite)
    │
    ▼

MeetingIntelligenceService.analyze(title:transcript:)
    │  AIService (Ollama → OpenAI → Claude → Gemini fallback)
    │  Fallback: keyword extraction from raw text
    │
    ├─► meeting.summary
    ├─► meeting.decisions
    ├─► meeting.actionItems
    ├─► meeting.suggestedTaskTitles
    └─► meeting.commitments [CommitmentItem]
```

---

## Component Audits

### 1. RecordingService

**Recognition session lifecycle:**
- `SFSpeechRecognizer` on-device (preferred) or network
- Network sessions expire at ~60 seconds (Apple limit)
- Transparent restart: when `isFinal == true` during active recording, `transcriptPrefix` accumulates the finalized text and a new session starts
- Session chain: `prefix₀ + result₁ → prefix₁ + result₂ → … → finalTranscript`

**Transcript accumulation formula:**
```
transcript = transcriptPrefix + currentSessionText
```
Where `transcriptPrefix` grows by one session each time `isFinal` fires.

**Audio file:** Written to `Application Support/Orin/Recordings/meeting-<ISO8601>.caf`. AVAudioFile is closed and flushed on `tapState.disarm()` during `stopRecording()`.

**Integrity guards:**
- `tapState.hadWriteFailure` — set if AVAudioFile write fails, surfaced as user-visible error after recording stops
- Empty file check — `size == 0` detection after stop

**Speaker labeling:** `speakerTranscript = "Me: \(transcript)"` — entire mic stream labeled as single speaker.

**Issues found:**
- ⚠️ `speakerTranscript` prefixes the ENTIRE accumulated transcript with "Me: " on every update, not per utterance. For MeetingDetailView display this is fine, but for diarization it collapses all mic speech into one labeled block.

---

### 2. SystemAudioCaptureService

**Capture pipeline:**
- `SCStream` with `capturesAudio = true`, `excludesCurrentProcessAudio = true`
- `2×2 px` minimal video config to reduce CPU overhead
- `CMSampleBuffer → AVAudioPCMBuffer` conversion via `convertToAVAudioPCMBuffer`
- Feed to `SFSpeechAudioBufferRecognitionRequest` via `SystemAudioTapState`
- Same ~60s session restart pattern as RecordingService

**Permissions:**
- Requires `com.apple.security.screen-recording` entitlement + user approval
- Graceful fallback: if SCStream fails, `isCapturing = false` and `isAvailable = false`; mic recording unaffected

**Issues found:**
- ⚠️ Parallel SFSpeechRecognizer instances (mic + system audio) share the same Apple Speech framework rate limits. On-device recognition avoids this, but network recognition from two streams simultaneously may hit rate limits more quickly.
- ⚠️ `excludesCurrentProcessAudio = true` means Orin's own audio (e.g., notification sounds) is excluded. This is correct behavior but may miss audio from Orin integrations.

---

### 3. TranscriptStore

**Session lifecycle:**
```
beginSession() → startCheckpointTimer (3s)
  ↓ every updateMic/updateParticipant
recomputeLive() → liveTranscript
  ↓ every 3s
checkpoint() → meeting.transcript (SwiftData) + UserDefaults backup
  ↓ on stop
finalize() → 1.5s wait + best-of-N + safeSaveWithRetry
  ↓
endSession() → clear orphan keys
```

**Integrity invariants (all verified):**
1. **Empty-overwrite protection:** `updateMic("")` skips if `micLabeledText` already has content
2. **Checkpoint growth guard:** skips if `liveTranscript.count <= persistedLength`
3. **Finalize truncation guard:** never writes shorter text than what's in the model
4. **Best-of-N:** candidates = [freshLive, snapshotLive, snapshotPersisted, modelTranscript] → longest wins
5. **Orphan recovery:** UserDefaults backup + TranscriptChunk records enable reconstruction after crash

**TranscriptChunk persistence (Phase 3 implementation):**
- Written when content grows ≥ 10 characters since last chunk
- Used as third recovery candidate in `recoverOrphan()`
- Each chunk stores: meetingId, speaker ("mic"/"participant"), full labeled text at that point

**Duplicate update risk:**
- Both `MainContainerView` and `MeetingDetailView` call `updateMic()` for the same transcript update
- `updateMic()` uses replacement (not append): `micLabeledText = labeledText`
- Calling twice with same value → idempotent, no duplication ✅

**Issues found:**
- ⚠️ `mergeTranscripts(mic:participant:)` concatenates the FULL mic and participant transcripts with `\n\n` separator. For long meetings this means the entire participant transcript block is at the bottom, not interleaved by time. This is a known limitation of source-channel labeling (not true diarization).

---

### 4. MeetingItem Model

**Fields relevant to transcript pipeline:**
| Field | Type | Populated by |
|---|---|---|
| transcript | String | TranscriptStore.checkpoint/finalize |
| summary | String | MeetingIntelligenceService (manual only — **UNWIRED**) |
| decisions | [String] | MeetingIntelligenceService (manual only — **UNWIRED**) |
| actionItems | [String] | MeetingIntelligenceService (manual only — **UNWIRED**) |
| suggestedTaskTitles | [String] | MeetingIntelligenceService (manual only — **UNWIRED**) |
| commitments | [CommitmentItem] | MeetingIntelligenceService (manual only — **UNWIRED**) |
| durationSeconds | TimeInterval | TranscriptStore.finalize(elapsed:) |
| audioFilePath | String? | TranscriptStore.finalize(audioURL:) |

**CRITICAL BUG — Auto-analysis not wired:**
`orin.meetings.autoAnalyze` and `orin.meetings.minDurationMinutes` exist as AppStorage keys and are configurable in SettingsView, but are **never read** anywhere in the recording pipeline. Analysis only runs when the user taps the "Analyze" button in `MeetingDetailView`.

---

### 5. MeetingIntelligenceService

**Analysis pipeline:**
```swift
func analyze(title: String, transcript: String) async -> MeetingAnalysis {
    summaryResult = await aiService.generateSummary(for: transcript)
    summary       = summaryResult.fallbackUsed ? fallbackSummary() : summaryResult.text
    decisions     = extractLines(matching: ["decided", "decision", "agreed", "approved"])
    commitments   = extractLines(matching: ["i will", "i'll", "we will", "follow up", ...])
    actionItems   = extractLines(matching: ["action", "todo", "to do", "next step", ...])
    suggestedTasks = buildSuggestedTasks(commitments + actionItems)
}
```

**AI summary:** Calls `aiService.generateSummary()` with Ollama→OpenAI→Claude→Gemini fallback.

**Extraction:** Keyword-based line scanning (not semantic). Returns up to 8 lines per category.

**Limitations:**
- Decisions/commitments/actions use simple line-level keyword matching — multi-line utterances or speech that spans line breaks in the transcript may be missed
- `buildSuggestedTasks` deduplicates via `NSOrderedSet`, capped at 6 tasks
- If transcript has only "Me: " and "Participant: " labels, the keyword matching still works since it searches the full text

---

## Summary of Critical Issues

| Issue | Severity | Fix |
|---|---|---|
| Auto-analysis not triggered after recording stops | CRITICAL | Wire `orin.meetings.autoAnalyze` in MainContainerView + MeetingDetailView finalize path |
| Single CSV export format missing | HIGH | Add `.csv` to `MeetingExportFormat` + `MeetingDataService` |
| Bulk ZIP export missing | HIGH | Implement `exportMeetingsZip()` in `MeetingDataService` |
| Summary/decisions/etc never auto-populated | CRITICAL | Follows from auto-analysis fix above |
