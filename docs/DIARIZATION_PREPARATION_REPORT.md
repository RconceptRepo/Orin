# Diarization Preparation Report

**Date:** 2026-05-31

---

## Current State: Source-Channel Labeling

Orin's transcript pipeline assigns speaker labels based on audio source channel:

| Audio source | `TranscriptSegment.source` | `TranscriptSegment.speakerLabel` |
|---|---|---|
| Local microphone (AVAudioEngine) | `"mic"` | `"Me"` |
| System audio (ScreenCaptureKit) | `"participant"` | `"Participant"` |

This is **not** true speaker diarization. The "Participant" label represents all remote audio mixed together — in a 5-person meeting, all 4 remote voices are one "Participant" block.

---

## Future State: Speaker Identification

When speaker identification is added (via FluidAudio/pyannote or other local model):

| Audio source | `source` | `speakerLabel` (with diarization) |
|---|---|---|
| Local mic | `"mic"` | `"Me"` (always) |
| System audio (voice cluster A) | `"participant"` | `"Speaker 1"` |
| System audio (voice cluster B) | `"participant"` | `"Speaker 2"` |
| System audio (voice cluster C) | `"participant"` | `"Speaker 3"` |

The `source` field NEVER changes — it reflects physical reality. Only `speakerLabel` is updated by the diarization pass.

---

## Interfaces Created

### `SpeakerIdentificationProvider` (in `Providers/Protocols/DiarizationProvider.swift`)

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

**Contract:**
- Input: ordered `[TranscriptSegment]` with source-channel labels
- Output: same segments with `speakerLabel` possibly updated
- All other fields preserved
- Never throws; returns input unchanged on failure

**Current implementation:** `SourceChannelSpeakerProvider` — identity function (no-op, assigns "Me"/"Participant" which are already set by `ConversationTimelineBuilder`)

**Future implementation:** `FluidAudioDiarizationProvider` — runs pyannote CoreML on the audio file, clusters voices, renames "Participant" segments to "Speaker 1", "Speaker 2", etc.

---

### `TranscriptSegmentBuilder` (in `Providers/Protocols/DiarizationProvider.swift`)

```swift
protocol TranscriptSegmentBuilder {
    func buildSegments(
        meetingId: UUID,
        audioFile: URL?,
        existingChunks: [TranscriptChunk]
    ) async -> [TranscriptSegment]
}
```

**Current implementation:** `ChunkBasedSegmentBuilder` — uses existing `TranscriptChunks` (no audio access needed)

**Future implementation:** `WhisperSegmentBuilder` — runs whisper.cpp with word-level timestamps for finer-grained segmentation (replaces chunk-based deltas with actual utterance boundaries)

---

## How to Add True Diarization

### Step 1: Add FluidAudio dependency

```swift
// Package.swift
.package(url: "https://github.com/FluidInference/FluidAudio", from: "0.14.7"),
```

### Step 2: Implement `SpeakerIdentificationProvider`

```swift
import FluidAudio

@MainActor
final class FluidAudioDiarizationProvider: SpeakerIdentificationProvider {
    var providerName: String { "FluidAudio (pyannote CoreML)" }

    func identifySpeakers(
        in segments: [TranscriptSegment],
        audioFile: URL?
    ) async -> [TranscriptSegment] {
        guard let audio = audioFile else { return segments }

        // 1. Run diarization on the audio file
        let diarizer = try? await OfflineDiarizerManager.load()
        let diarization = try? await diarizer?.diarize(audioURL: audio)
        // Returns: [(startTime, endTime, speakerId), ...]

        // 2. Map diarization clusters to speaker labels
        let speakerMap = buildSpeakerMap(diarization)
        // speakerMap: [speakerId: "Speaker 1" | "Speaker 2" | ...]

        // 3. Assign labels to segments by timestamp overlap
        return segments.map { segment in
            guard segment.source == "participant",
                  let speakerId = findSpeaker(diarization, at: segment.timestamp),
                  let label = speakerMap[speakerId] else { return segment }
            var updated = segment
            updated.speakerLabel = label
            return updated
        }
    }
}
```

### Step 3: Register the provider in `OrinApp`

```swift
// Replace SourceChannelSpeakerProvider with FluidAudioDiarizationProvider
let speakerProvider = FluidAudioDiarizationProvider()
services.register(speakerProvider, for: any SpeakerIdentificationProvider)
```

### Step 4: Call in `TranscriptStore.buildTimelineSegments()`

```swift
// Current: segments are built and saved directly
// Future: add identification pass before saving
let speakerProvider = ServiceContainer.shared.resolve((any SpeakerIdentificationProvider).self)
let identified = await speakerProvider.identifySpeakers(
    in: merged,
    audioFile: meeting.audioFilePath.map { URL(fileURLWithPath: $0) }
)
for segment in identified { context.insert(segment) }
```

---

## No Code Changes Required to Core Models

Because `TranscriptSegment.speakerLabel` is a mutable stored property, updating speaker labels after diarization requires only:

```swift
segment.speakerLabel = "Speaker 1"
try context.save()
```

The `ConversationTimelineView` automatically reflects updated labels — no UI changes needed.

---

## Persistence Layer Stability

The persistence layer (`TranscriptSegment` model) is designed to accommodate future speaker labels without schema changes:

| Label today | Label with diarization | Change needed |
|---|---|---|
| "Me" | "Me" | None |
| "Participant" | "Speaker 1", "Speaker 2", "Speaker 3" | Update `speakerLabel` field only |

The `source` field ("mic"/"participant") always reflects the physical audio origin and never changes. This preserves the ability to re-run diarization and produce different speaker assignments without losing the underlying audio source information.

---

## Research Reference

From the deep-research workflow (2026-05-30):
- **FluidAudio v0.14.7** (Apache 2.0, CoreML, Apple Neural Engine): provides pyannote 3.1 compiled for macOS Apple Silicon. Three models: Sortformer (≤4 speakers), LS-EEND (≤10 speakers, 100ms updates), WeSpeaker/pyannote (highest accuracy, ≥5s chunks).
- **Implementation effort:** 4–8 weeks from interface to production
- **RAM budget:** whisper.cpp large (~3.9 GB) + diarization pipeline (< 1 GB) = fits 8 GB unified memory
- **Repo:** github.com/FluidInference/FluidAudio

---

## Summary

| Interface | File | Status |
|---|---|---|
| `SpeakerIdentificationProvider` | `Providers/Protocols/DiarizationProvider.swift` | ✅ Created |
| `TranscriptSegmentBuilder` | `Providers/Protocols/DiarizationProvider.swift` | ✅ Created |
| `SourceChannelSpeakerProvider` | `Providers/macOS/SourceChannelSpeakerProvider.swift` | ✅ Default impl |
| `ChunkBasedSegmentBuilder` | `Providers/macOS/SourceChannelSpeakerProvider.swift` | ✅ Default impl |
| `FluidAudioDiarizationProvider` | Not yet created | 🔮 Future |
| `WhisperSegmentBuilder` | Not yet created | 🔮 Future |
