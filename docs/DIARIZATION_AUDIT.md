# Diarization Audit

**Date:** 2026-05-31  
**Scope:** Current audio architecture capabilities and limitations relative to multi-speaker diarization.

---

## Current Audio Architecture

### Recording Layer

```
Microphone (local user)
    │
    ▼
AVAudioEngine (AVAudioInputNode tap)
    │  Format: hardware capture format (typically 44.1 kHz, 16/32-bit PCM)
    │  Written to disk: meeting-<ISO8601>.caf (Core Audio Format, uncompressed PCM)
    │
    └─► SFSpeechAudioBufferRecognitionRequest
            │  On-device ASR (preferred) or network ASR
            │  ~60s session limit (network); transparent restart via transcriptPrefix
            │  Outputs: partial + final recognition results (formattedString)
            │
            ▼ Every ~0.5-2s
        RecordingService.transcript ("accumulated mic text")
        RecordingService.speakerTranscript ("Me: {text}")

System Audio (all remote participants, combined)
    │
    ▼
ScreenCaptureKit SCStream (capturesAudio=true, excludesCurrentProcessAudio=true)
    │  Config: 2×2 px video (minimal overhead), audio capture only
    │  CMSampleBuffer → AVAudioPCMBuffer conversion
    │
    └─► SFSpeechAudioBufferRecognitionRequest (separate instance)
            │  Parallel recognition, same ~60s restart pattern
            │
            ▼
        SystemAudioCaptureService.transcript ("accumulated participant text")
        SystemAudioCaptureService.participantSpeakerTranscript ("Participant: {text}")
```

### Persistence Layer

```
TranscriptStore
    │  updateMic("Me: ...") → micLabeledText
    │  updateParticipant("Participant: ...") → participantLabeledText
    │  mergeTranscripts(mic, participant) → liveTranscript
    │  checkpoint every 3s → MeetingItem.transcript
    │  TranscriptChunk per ≥10-char growth
    │
    ▼ At recording stop
TranscriptStore.finalize()
    │
    ▼
ConversationTimelineBuilder.buildSegments(from: [TranscriptChunk], meetingId:)
    │  Separates mic chunks vs. participant chunks
    │  Computes deltas between consecutive chunks
    │  Creates TranscriptSegment per delta
    │  mergeConsecutive (20s window, respects source switches)
    │
    ▼
[TranscriptSegment] persisted to SwiftData
```

### TranscriptSegment Data Model

```swift
@Model final class TranscriptSegment {
    var id: UUID
    var meetingId: UUID
    var timestamp: Date       // wall-clock time of the chunk
    var source: String        // "mic" | "participant" — PHYSICAL, never changes
    var speakerLabel: String  // "Me" | "Participant" — LOGICAL, updatable by diarization
    var text: String          // delta text for this segment
    var sequenceIndex: Int    // tie-break ordering
}
```

**Critical design property:** `source` and `speakerLabel` are intentionally separate.
- `source` = physical audio origin. Immutable after creation. Truth about which channel produced the audio.
- `speakerLabel` = logical identity. Mutable. `SpeakerIdentificationProvider` updates this without changing `source`.

This separation means: diarizing "Participant" into "Speaker 1", "Speaker 2", "Speaker 3" requires only updating `speakerLabel` — no schema migration, no new models.

### SpeakerIdentificationProvider Protocol (already implemented)

```swift
@MainActor
protocol SpeakerIdentificationProvider: AnyObject {
    var providerName: String { get }
    func identifySpeakers(
        in segments: [TranscriptSegment],
        audioFile: URL?
    ) async -> [TranscriptSegment]
}
```

Current implementation: `SourceChannelSpeakerProvider` — identity function, returns segments unchanged ("Me"/"Participant" already set by builder).

**Future diarization implementation replaces `SourceChannelSpeakerProvider`** without touching any other code.

### TranscriptSegmentBuilder Protocol (already implemented)

```swift
protocol TranscriptSegmentBuilder {
    func buildSegments(
        meetingId: UUID,
        audioFile: URL?,
        existingChunks: [TranscriptChunk]
    ) async -> [TranscriptSegment]
}
```

Current implementation: `ChunkBasedSegmentBuilder` — uses existing TranscriptChunks. A `WhisperSegmentBuilder` using whisper.cpp word-level timestamps would drop in here.

---

## Current Labeling: What We Have

| Label | Source | What it represents | Accuracy |
|---|---|---|---|
| `Me:` | AVAudioEngine mic | Local user — everything spoken into the microphone | High (single source) |
| `Participant:` | ScreenCaptureKit | ALL remote audio combined — N speakers mixed into one stream | Low for multi-speaker |

### What "Participant" Actually Is

In a 5-person Zoom call:
- `Me:` = 1 voice (correct, isolated mic)
- `Participant:` = 4 voices mixed by the OS audio mixer

The `Participant` label is source-channel labeling, not speaker diarization. All remote voices are indistinguishable at the capture layer — Orin receives a single mixed PCM stream.

---

## Audio File Details

| Property | Value | Diarization relevance |
|---|---|---|
| Format | `.caf` (Core Audio Format) | ✅ Standard format, whisper.cpp and FluidAudio can read |
| Sample rate | Hardware native (44.1–48 kHz) | ✅ All diarization models accept 16 kHz (downsampled) |
| Bit depth | 32-bit float or 16-bit PCM | ✅ Compatible |
| Channels | 1 (mono mic) + 1 (mono system audio) | ⚠️ System audio may be stereo; mono preferred for diarization |
| Max duration stored | Retention policy (30–180 days) | ✅ Files available for post-processing |
| Location | `Application Support/Orin/Recordings/` | ✅ Accessible to app |

---

## What Is Missing for Diarization

| Capability | Status | Gap |
|---|---|---|
| Per-utterance timestamps | ❌ Missing | SFSpeechRecognizer `isFinal` fires at ~60s sessions, not per utterance |
| Speaker embeddings | ❌ Missing | No voice fingerprinting at any point in the pipeline |
| Audio segmentation by speaker | ❌ Missing | System audio is one mixed stream |
| Word-level timestamps | ❌ Missing | SFSpeechRecognizer provides `segmentsAndConfidences` but these are text segments, not speaker-level |
| Silence detection | ❌ Missing | No VAD (Voice Activity Detection) implemented |
| Speaker clustering | ❌ Missing | No cross-utterance speaker consistency tracking |

### Critical Gap: Participant Audio is Pre-Mixed

This is the fundamental constraint for Orin's diarization challenge:

```
Remote Speaker A ─┐
Remote Speaker B ─┤─► OS Audio Mixer ─► Orin SCStream (one stream)
Remote Speaker C ─┘
```

Diarization must operate on this mixed stream, which is harder than diarizing an unmixed multi-channel recording. The audio quality varies with codec (Zoom OPUS, Teams SATIN, etc.) and includes speech artifacts from VoIP processing.

---

## What the Architecture Already Supports

The existing design is **ready to accept diarization** with minimal changes:

1. **`SpeakerIdentificationProvider`** — plug-in point for any diarization implementation
2. **`TranscriptSegment.speakerLabel`** — mutable field for updating labels post-analysis
3. **`TranscriptSegmentBuilder`** — plug-in point for whisper.cpp-based segmentation
4. **`audioFilePath`** on `MeetingItem` — audio available for post-processing
5. **`MeetingKnowledgeSnapshot`** — can store speaker-labeled results for folder intelligence
6. **Vault encryption** — can store speaker embeddings securely if needed

The pipeline is designed to accept diarization as an optional post-processing step with zero disruption to existing functionality.
