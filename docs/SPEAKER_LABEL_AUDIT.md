# Speaker Label Audit

**Date:** 2026-05-30

---

## What Is Implemented

Orin uses **source-channel labeling** — not speaker diarization. The two audio sources (microphone and system audio) are independently transcribed and labeled based on their capture origin, not by speaker identity.

### Label Assignment

| Label | Source | What It Represents |
|---|---|---|
| `Me:` | `RecordingService` (AVAudioEngine mic input) | Everything spoken into the local microphone |
| `Participant:` | `SystemAudioCaptureService` (ScreenCaptureKit system audio) | Everything playing through the system audio output — this includes ALL remote participants, shared audio, and any audio not originating from the local mic |

### Implementation Details

**`RecordingService.speakerTranscript`:**
```swift
var speakerTranscript: String {
    guard !transcript.isEmpty else { return "" }
    return "Me: \(transcript)"
}
```
The entire mic transcript is wrapped once with "Me: ". This is a session-level label, not a per-utterance label. A 60-minute continuous mic transcript becomes one "Me: [all speech]" block.

**`SystemAudioCaptureService.participantSpeakerTranscript`:**
```swift
var participantSpeakerTranscript: String {
    guard !transcript.isEmpty else { return "" }
    return "Participant: \(transcript)"
}
```
Same pattern — one session-level "Participant: [all audio]" block.

**`TranscriptStore.mergeTranscripts(mic:participant:)`:**
```swift
static func mergeTranscripts(mic: String, participant: String) -> String {
    switch (mic.isEmpty, participant.isEmpty) {
    case (true,  true):  return ""
    case (false, true):  return mic
    case (true,  false): return participant
    case (false, false): return "\(mic)\n\n\(participant)"
    }
}
```
The merge is simple concatenation of two blocks, separated by a blank line. Temporal order is not preserved — the full mic block precedes the full participant block regardless of when utterances occurred.

---

## What This Is NOT

| Capability | Status |
|---|---|
| Per-utterance "Me said X at 0:32, Participant said Y at 0:35" | ❌ Not implemented |
| Multiple participant identification ("Speaker 1", "Speaker 2", "Speaker 3") | ❌ Not implemented |
| Speaker embedding / voice fingerprinting | ❌ Not implemented |
| Turn-taking detection (who spoke when) | ❌ Not implemented |
| Overlap detection (simultaneous speakers) | ❌ Not implemented |

---

## Structural Limitations

### 1. "Participant" = All Remote Audio
`SystemAudioCaptureService` captures all system audio output — this includes music, videos, notification sounds, and crucially, ALL remote meeting participants combined. A 5-person Teams call produces one "Participant:" block containing all five voices mixed together. There is no per-person separation.

### 2. Labels Are Session-Level, Not Utterance-Level
Both "Me:" and "Participant:" are prefixed once to the entire session transcript. The display in `MeetingDetailView` shows two text blocks, not an interleaved conversation.

**Example of actual output:**
```
Me: Hello everyone let's get started we need to discuss the Q3 budget 
there are three main items first the marketing spend second the engineering 
headcount and third the product roadmap...

Participant: Thanks for joining today our main concern is the headcount 
increase we saw last quarter and whether that's sustainable given the 
revenue projections for next year...
```

**What users might expect (but do NOT get):**
```
[0:00] Me: Hello everyone, let's get started.
[0:03] Participant (Alice): Thanks for joining.
[0:06] Me: We need to discuss the Q3 budget.
[0:09] Participant (Bob): Our main concern is headcount.
```

### 3. Mic Speech Can Appear in System Audio
In loopback scenarios (e.g., headphone-mic combinations on MacBooks), the speaker's voice may appear faintly in system audio output through room acoustics or hardware loopback. `excludesCurrentProcessAudio = true` excludes Orin's own audio but not audio from the OS mixer.

---

## Accuracy of Current Labeling

| Scenario | Accuracy |
|---|---|
| 1-on-1 call (local speaker + 1 remote) | ✅ "Me" = local; "Participant" = remote |
| 3-person call (1 local + 2 remote) | ⚠️ "Me" = local; "Participant" = both remotes mixed |
| 5-person Teams call | ⚠️ "Me" = local; "Participant" = all 4 remotes mixed |
| In-person meeting recorded | ⚠️ "Me" = person holding device; "Participant" = nothing (no system audio) |
| Screen share with shared audio | ⚠️ Shared audio appears in "Participant" block |
| User plays music during call | ⚠️ Music appears in "Participant" block |

---

## Path to True Diarization

For reference (implementation NOT in scope here), true speaker diarization would require:

1. **Speaker embedding model:** e.g., pyannote Community-1 via FluidAudio (CoreML, Apple Neural Engine)
2. **Timestamp-aligned transcription:** whisper.cpp with word-level timestamps
3. **Segment merging:** align diarization segments (speaker X: 0:00–0:15) with transcription segments to produce `[timestamp, speaker, text]` triples
4. **Storage model:** `TranscriptSegment` — add `timestamp: Date`, `speaker: String`, `text: String` to replace the current string concatenation approach

Research findings (from deep-research workflow): FluidAudio v0.14.7 provides CoreML-compiled pyannote 3.1 (Sortformer: ≤4 speakers; LS-EEND: ≤10 speakers). Implementation effort: 4–8 weeks. This is documented in the research report.

---

## Current Labeling — Verdict

| Property | Value |
|---|---|
| Implementation type | Source-channel labeling |
| Label granularity | Session-level (not per-utterance) |
| Speaker count | 2 channels only (Me / Participant) |
| Accuracy for 1:1 calls | High |
| Accuracy for group calls | Low (all remote voices merged) |
| True diarization | Not implemented |
