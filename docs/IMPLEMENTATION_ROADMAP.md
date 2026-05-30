# Speaker Diarization Implementation Roadmap

**Date:** 2026-05-31  
**Recommendation:** YES — implement in three phases  
**Total effort estimate:** 9–17 weeks across 3 phases

---

## Phase 1: Speaker N Labels (4–6 weeks)

### Goal
Replace "Participant:" with "Speaker 1:", "Speaker 2:", "Speaker 3:" etc. based on voice clustering.

### Scope
- Post-processing only (not real-time)
- No persistent speaker identity across meetings
- Speaker labels are local to each meeting session
- User opt-in via Settings toggle

### Deliverables

#### 1.1 Package Integration (1 week)
```swift
// Package.swift
.package(url: "https://github.com/FluidInference/FluidAudio", from: "0.14.7")

// Target dependency
.product(name: "FluidAudio", package: "FluidAudio")
```

**Entitlements required:** None beyond existing Screen Recording (for SCStream).

**Model download:** `OfflineDiarizerManager.prepareModels()` — show progress in Settings. Models stored in `Application Support/Orin/DiarizationModels/`.

#### 1.2 FluidAudioDiarizationProvider (2 weeks)

New file: `Sources/Orin/Providers/macOS/FluidAudioDiarizationProvider.swift`

```swift
import FluidAudio

@MainActor
final class FluidAudioDiarizationProvider: SpeakerIdentificationProvider {
    var providerName: String { "FluidAudio (Sortformer)" }

    func identifySpeakers(
        in segments: [TranscriptSegment],
        audioFile: URL?
    ) async -> [TranscriptSegment] {
        guard let audio = audioFile else { return segments }

        // 1. Resample to 16 kHz mono
        let resampled = try? await AudioResampler.resampleToMono16k(from: audio)
        guard let audioForDiarization = resampled else { return segments }
        defer { try? FileManager.default.removeItem(at: audioForDiarization) }

        // 2. Run diarization
        let diarizer = try? await OfflineDiarizerManager.load(model: .sortformer)
        guard let result = try? await diarizer?.diarize(audioURL: audioForDiarization)
        else { return segments }

        // 3. Find meeting start time for offset calculation
        let meetingStart = segments.min(by: { $0.timestamp < $1.timestamp })?.timestamp ?? Date()

        // 4. Map diarization clusters to speaker labels
        let speakerMap = buildSpeakerMap(result: result, meetingStart: meetingStart, micSegments: segments.filter { $0.source == "mic" })

        // 5. Update segment labels
        return segments.map { segment in
            guard segment.source == "participant" else { return segment }
            let offset = segment.timestamp.timeIntervalSince(meetingStart)
            guard let speaker = findSpeaker(in: result, at: offset) else { return segment }
            var updated = segment
            updated.speakerLabel = speakerMap[speaker] ?? "Participant"
            return updated
        }
    }

    // "spkA" that correlates with mic timestamps → "Me" (ignored for participant segments)
    // "spkB" → "Speaker 1", "spkC" → "Speaker 2", etc.
    private func buildSpeakerMap(
        result: DiarizationResult,
        meetingStart: Date,
        micSegments: [TranscriptSegment]
    ) -> [String: String] {
        var map: [String: String] = [:]
        var speakerCounter = 1

        // Sort speakers by first appearance time for consistent numbering
        let speakersByAppearance = result.segments
            .sorted { $0.startTime < $1.startTime }
            .compactMap { $0.speakerId }

        var seenSpeakers = [String]()
        for speaker in speakersByAppearance where !seenSpeakers.contains(speaker) {
            seenSpeakers.append(speaker)
            // Check if this speaker correlates with the mic (local user)
            let isMic = correlatesWithMic(speaker: speaker, result: result,
                                           micSegments: micSegments, meetingStart: meetingStart)
            if !isMic {
                map[speaker] = "Speaker \(speakerCounter)"
                speakerCounter += 1
            }
        }
        return map
    }

    private func correlatesWithMic(
        speaker: String,
        result: DiarizationResult,
        micSegments: [TranscriptSegment],
        meetingStart: Date
    ) -> Bool {
        // A speaker whose diarization segments heavily overlap with mic segment timestamps is "Me"
        let speakerSegments = result.segments.filter { $0.speakerId == speaker }
        let micOffsets = micSegments.map { $0.timestamp.timeIntervalSince(meetingStart) }

        var overlap = 0
        for micOffset in micOffsets {
            if speakerSegments.contains(where: { $0.startTime <= micOffset && $0.endTime >= micOffset }) {
                overlap += 1
            }
        }
        return !micOffsets.isEmpty && Double(overlap) / Double(micOffsets.count) > 0.5
    }

    private func findSpeaker(in result: DiarizationResult, at offset: TimeInterval) -> String? {
        result.segments
            .filter { $0.startTime <= offset && $0.endTime >= offset }
            .max(by: { ($0.endTime - $0.startTime) < ($1.endTime - $1.startTime) })?
            .speakerId
    }
}
```

#### 1.3 AudioResampler Utility (0.5 weeks)

New file: `Sources/Orin/Services/AudioResampler.swift`

```swift
import AVFoundation

enum AudioResampler {
    /// Converts audio file to 16 kHz mono PCM (required by FluidAudio).
    /// Returns URL of a temporary .wav file. Caller is responsible for cleanup.
    static func resampleToMono16k(from input: URL) async throws -> URL {
        let inputFile  = try AVAudioFile(forReading: input)
        let outputURL  = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString + ".wav")
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16000, channels: 1,
                                         interleaved: true)!
        let outputFile = try AVAudioFile(forWriting: outputURL,
                                         settings: outputFormat.settings)

        let converter  = AVAudioConverter(from: inputFile.processingFormat,
                                          to: outputFormat)!
        let bufferSize: AVAudioFrameCount = 4096
        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: bufferSize)!
        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: bufferSize * 4)!

        while true {
            try inputFile.read(into: inputBuffer)
            if inputBuffer.frameLength == 0 { break }
            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, status in
                status.pointee = .haveData
                return inputBuffer
            }
            if let error { throw error }
            try outputFile.write(from: outputBuffer)
        }
        return outputURL
    }
}
```

#### 1.4 Wire into TranscriptStore.buildTimelineSegments (0.5 weeks)

Update `TranscriptStore.buildTimelineSegments(for:context:)` to optionally run diarization:

```swift
private func buildTimelineSegments(for meeting: MeetingItem, context: ModelContext) {
    // ... existing chunk-to-segment logic ...

    // Optional: run diarization if enabled and audio file exists
    guard UserDefaults.standard.bool(forKey: "orin.diarization.enabled"),
          let audioPath = meeting.audioFilePath
    else { return }

    let audioURL = URL(fileURLWithPath: audioPath)
    let provider = ServiceContainer.shared.resolve(any SpeakerIdentificationProvider.self)

    Task { @MainActor [weak self] in
        guard let self else { return }
        let identified = await provider.identifySpeakers(
            in: merged, audioFile: audioURL
        )
        for (original, updated) in zip(merged, identified) {
            original.speakerLabel = updated.speakerLabel
        }
        context.safeSave(context: "diarization labels")
        self.log.info("diarization complete segments=\(identified.count)")
    }
}
```

#### 1.5 Settings UI (0.5 weeks)

Add to `SettingsView.meetingsSection`:
```swift
Toggle(isOn: $diarizationEnabled) {
    VStack(alignment: .leading, spacing: 2) {
        Text("Speaker identification")
        Text("Label speakers as Speaker 1, Speaker 2, etc. after recording ends. Requires ~300 MB download on first use. Best on 16 GB+ Macs.")
            .font(OrinFont.caption)
            .foregroundStyle(.secondary)
    }
}
.onChange(of: diarizationEnabled) { _, enabled in
    if enabled { Task { await downloadDiarizationModels() } }
}
```

#### 1.6 RAM Detection and Model Selection (0.5 weeks)

```swift
static func recommendedModel() -> DiarizationModel {
    let physicalMemoryGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
    switch physicalMemoryGB {
    case 0..<12: return .sortformer   // FluidAudio only, no whisper.cpp
    case 12..<24: return .sortformer  // FluidAudio + whisper.cpp medium
    default:     return .weSpeaker    // Full pipeline
    }
}
```

### Phase 1 Success Criteria
- [ ] "Participant" replaced with "Speaker 1", "Speaker 2" in ConversationTimeline
- [ ] Local user still correctly labeled "Me"
- [ ] Settings toggle enables/disables feature
- [ ] Fails gracefully (reverts to "Participant") if model unavailable
- [ ] All existing tests continue to pass
- [ ] Model downloaded and cached on first enable

---

## Phase 2: Persistent Speaker Identity (3–4 weeks)

### Goal
Recognize the same speaker across multiple meetings. "Speaker 1 from your Monday standups is always the same person."

### New Components

#### 2.1 Speaker Embedding Storage

New SwiftData model: `SpeakerEmbedding`

```swift
@Model final class SpeakerEmbedding {
    @Attribute(.unique) var id: UUID
    /// User-assigned identifier (may be "Speaker 1" until named in Phase 3)
    var labelId: String
    /// ECDH-encrypted d-vector (64-dimensional float array, ~256 bytes)
    var embeddingData: Data
    /// Meetings where this speaker was identified
    var meetingIds: [UUID]
    var createdAt: Date
    var lastSeenAt: Date
    var confidence: Double  // average recognition confidence
}
```

Store in existing Vault encryption layer for privacy.

#### 2.2 Cross-Meeting Speaker Matching

After each diarization run:
1. Extract speaker embeddings from `FluidAudio`
2. Compare to stored `SpeakerEmbedding` records using cosine similarity
3. If similarity > threshold (0.85): assign existing speaker id
4. If below threshold: create new `SpeakerEmbedding`

```swift
func matchOrCreateSpeaker(embedding: [Float]) -> String {
    let stored = try? ctx.fetch(FetchDescriptor<SpeakerEmbedding>())
    for speaker in stored ?? [] {
        let similarity = cosineSimilarity(embedding, speaker.embeddingVector)
        if similarity > 0.85 { return speaker.labelId }
    }
    let newSpeaker = SpeakerEmbedding(...)
    ctx.insert(newSpeaker)
    return "Speaker \(newSpeakerId)"
}
```

#### 2.3 Retroactive Label Updates

When a match is found across meetings, retroactively update `TranscriptSegment.speakerLabel` in older meetings:

```swift
func updateHistoricalLabels(from oldLabel: String, to newLabel: String, in meetingIds: [UUID])
```

### Phase 2 Success Criteria
- [ ] Same speaker recognized across meetings in the same folder
- [ ] Speaker embeddings encrypted in Vault
- [ ] Retroactive label updates work correctly
- [ ] Privacy: embeddings can be deleted ("forget this speaker")

---

## Phase 3: Named Speakers (2–3 weeks)

### Goal
Allow users to assign real names to speaker clusters: "Speaker 1 is Alice Chen."

### New Components

#### 3.1 Speaker Name Assignment UI

In `FolderDetailView.intelligenceTab`:
- Show speaker clusters for the folder
- Per-cluster: "Speaker 1 (3 meetings) → Assign name"
- Once named, all past and future segments for that speaker ID update

#### 3.2 Speaker Name Model

Extend `SpeakerEmbedding`:
```swift
var displayName: String?   // "Alice Chen", nil = still anonymous
var avatarInitials: String { displayName?.components(separatedBy: " ").compactMap(\.first).map(String.init).joined() ?? "S\(number)" }
```

#### 3.3 Named Speaker in Timeline

```
[00:03] Me: Good morning everyone.
[00:10] Alice: Thanks for joining.
[00:18] Me: Let's review the sprint.
[00:45] Alice: I finished the auth module.
[01:03] Bob: I'm blocked on staging access.
```

#### 3.4 AI Analysis Improvement

When speaker names are known, update `MeetingIntelligenceService` comprehensivePrompt:

```
## ACTION ITEMS
[OWNER: Alice Chen | TASK: Review auth PR | ...]
```

Instead of:
```
## ACTION ITEMS
[OWNER: Speaker 1 | TASK: Review auth PR | ...]
```

### Phase 3 Success Criteria
- [ ] User can assign names to speaker clusters
- [ ] Named speakers propagate across all meetings in folder
- [ ] AI analysis uses real names in action items
- [ ] Names persisted in Vault

---

## Technical Risk Register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| FluidAudio API changes | Low | Medium | Pin to specific version (v0.14.7) |
| DER accuracy lower than expected | Medium | Medium | Graceful fallback to "Participant" with user feedback |
| 8 GB Mac RAM pressure | High | Low | Auto-detect + use diarization-only (no whisper) on 8 GB |
| Model download fails | Medium | Low | Feature degraded, not broken |
| System audio quality poor (VoIP artifacts) | High | Medium | Lower confidence threshold, show "uncertain" label |
| Apple releases native API that obsoletes FluidAudio | Low | Positive | Swap provider with no pipeline changes |
| Flutter/Electron wrapper memory pressure | N/A | N/A | macOS native only |

---

## Effort Summary

| Phase | Duration | Engineer-weeks | Dependencies |
|---|---|---|---|
| Phase 1: Speaker Labels | 4–6 weeks | 4–6 | FluidAudio SPM, AudioResampler |
| Phase 2: Persistent Identity | 3–4 weeks | 3–4 | Phase 1, Vault storage, cosine similarity |
| Phase 3: Named Speakers | 2–3 weeks | 2–3 | Phase 2, Settings UI, AI prompt update |
| **Total** | **9–13 weeks** | **9–13** | |

---

## Compatibility Matrix

| Feature | 8 GB Mac | 16 GB Mac | 32 GB Mac |
|---|---|---|---|
| Speaker labels (FluidAudio only) | ✅ | ✅ | ✅ |
| Speaker labels (+ whisper.cpp) | ⚠️ medium model only | ✅ turbo | ✅ large |
| Persistent identity | ✅ | ✅ | ✅ |
| Named speakers | ✅ | ✅ | ✅ |
| Real-time diarization | ❌ | ❌ | ❌ |
