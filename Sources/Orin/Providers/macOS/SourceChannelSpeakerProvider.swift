import Foundation

// MARK: - SourceChannelSpeakerProvider
//
// Default macOS SpeakerIdentificationProvider.
// Uses the physical audio source to assign speaker labels:
//   mic         → "Me"          (local microphone = the user running Orin)
//   participant → "Participant" (system audio = all remote speakers combined)
//
// No audio analysis, no AI, no external services.  Runs instantly.
//
// This is the current production implementation.  Replace with a diarization
// provider (e.g. FluidAudioDiarizationProvider) when ready — the calling code
// only depends on the SpeakerIdentificationProvider protocol.

@MainActor
final class SourceChannelSpeakerProvider: SpeakerIdentificationProvider, Service {

    var providerName: String { "Source Channel (Me / Participant)" }

    func identifySpeakers(
        in segments: [TranscriptSegment],
        audioFile: URL?
    ) async -> [TranscriptSegment] {
        // Source-channel labeling is already baked in during ConversationTimelineBuilder.
        // This pass is a no-op but exists so consumers don't need to know which provider
        // is active — they always call identifySpeakers and get back labeled segments.
        return segments
    }
}

// MARK: - ChunkBasedSegmentBuilder
//
// Default TranscriptSegmentBuilder.
// Derives TranscriptSegments from existing TranscriptChunks via ConversationTimelineBuilder.
// Requires no audio access — all data is in the SwiftData store.

final class ChunkBasedSegmentBuilder: TranscriptSegmentBuilder, Service {

    func buildSegments(
        meetingId: UUID,
        audioFile: URL?,
        existingChunks: [TranscriptChunk]
    ) async -> [TranscriptSegment] {
        let chunks = existingChunks.filter { $0.meetingId == meetingId }
        return ConversationTimelineBuilder.buildSegments(from: chunks, meetingId: meetingId)
    }
}
