import Foundation

// MARK: - SpeakerIdentificationProvider
//
// Abstracts the speaker-identification layer of the transcript pipeline.
//
// Current behaviour (source-channel labeling):
//   source="mic"         → speakerLabel="Me"
//   source="participant" → speakerLabel="Participant"
//
// Future behaviour (diarization, e.g. via FluidAudio + pyannote CoreML):
//   source="mic"         → speakerLabel="Me"          (always — microphone = local user)
//   source="participant" → speakerLabel="Speaker 1"   (first remote voice cluster)
//   source="participant" → speakerLabel="Speaker 2"   (second remote voice cluster)
//   source="participant" → speakerLabel="Speaker 3"   (third remote voice cluster)
//
// Contract:
//   - Input segments are already ordered by timestamp.
//   - Implementations must return segments in the SAME order.
//   - Only `speakerLabel` may be changed; all other fields are preserved.
//   - Implementations must never throw — return input unchanged on failure.
//
// macOS default implementation: SourceChannelSpeakerProvider (in macOS/ directory).
// Future implementation: FluidAudioDiarizationProvider (not yet implemented).

@MainActor
protocol SpeakerIdentificationProvider: AnyObject {

    /// Human-readable name for this provider.  Shown in diagnostic logs.
    var providerName: String { get }

    /// Assigns speaker labels to `segments`.
    ///
    /// - Parameters:
    ///   - segments: Ordered `TranscriptSegment` values produced by `TranscriptSegmentBuilder`.
    ///   - audioFile: Optional path to the recorded `.caf` file.
    ///     Diarization implementations use this for audio analysis.
    ///     Source-channel implementations ignore it.
    /// - Returns: The same segments with `speakerLabel` possibly updated.
    func identifySpeakers(
        in segments: [TranscriptSegment],
        audioFile: URL?
    ) async -> [TranscriptSegment]
}

// MARK: - TranscriptSegmentBuilder
//
// Abstracts the production of TranscriptSegments from raw audio and transcript data.
//
// Current implementation: ChunkBasedSegmentBuilder
//   Derives segments from TranscriptChunks (already persisted during recording).
//   No audio analysis required.  Fast, local, offline.
//
// Future implementation: WhisperSegmentBuilder
//   Derives segments by running whisper.cpp with word-level timestamps on the
//   audio file, producing finer-grained per-utterance segments.
//   Requires a local whisper.cpp server endpoint.
//
// When to implement WhisperSegmentBuilder:
//   When the user opts in to post-meeting transcription (not real-time).
//   The existing SFSpeechRecognizer pipeline handles real-time display.

protocol TranscriptSegmentBuilder {

    /// Builds `TranscriptSegment` values for the given meeting.
    ///
    /// - Parameters:
    ///   - meetingId: The `MeetingItem.id` to stamp on each segment.
    ///   - audioFile: Optional path to the recorded audio file.
    ///   - existingChunks: `TranscriptChunk` records already in the store.
    ///     Chunk-based builders use these; audio-based builders may ignore them.
    /// - Returns: Segments ordered by timestamp, not yet merged.
    func buildSegments(
        meetingId: UUID,
        audioFile: URL?,
        existingChunks: [TranscriptChunk]
    ) async -> [TranscriptSegment]
}
