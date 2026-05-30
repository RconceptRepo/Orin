import Foundation

// MARK: - ConversationTimelineBuilder
//
// Transforms raw TranscriptChunks (crash-recovery layer) into ordered
// TranscriptSegments (conversation-timeline layer).
//
// # Algorithm
//
//   1. Separate chunks by speaker ("mic" / "participant").
//   2. For each speaker, compute the DELTA text between consecutive chunks.
//      (Chunks store the full accumulated transcript; delta = new text added.)
//   3. Create a TranscriptSegment for each meaningful delta.
//   4. Sort all segments by timestamp → interleaved conversation order.
//   5. Merge consecutive same-speaker segments that are not separated by the
//      other speaker and fall within `mergeWindowSeconds` (default 20 s).
//      This collapses the many small chunks (written every 10 chars) into
//      readable speech blocks.
//
// # Merge window rationale
//
// Chunks are written every ~10-character growth. At 130 words/min ≈ 11 chars/s,
// that's roughly one chunk per second. A 20-second merge window collapses
// ~20 raw segments into one readable block per turn, producing 2–5 turns per
// minute per speaker — enough granularity to show conversation flow.
//
// # Usage
//
//   let rawSegments = ConversationTimelineBuilder.buildSegments(
//       from: chunks, meetingId: meeting.id
//   )
//   let merged = ConversationTimelineBuilder.mergeConsecutive(rawSegments)
//   // → insert merged segments into ModelContext

enum ConversationTimelineBuilder {

    // MARK: - Public API

    /// Build `TranscriptSegment` values from a set of `TranscriptChunk` records.
    ///
    /// - Parameters:
    ///   - chunks: All chunks for the meeting, in any order.
    ///   - meetingId: The `MeetingItem.id` to stamp on each segment.
    /// - Returns: Segments sorted by timestamp, ready for `mergeConsecutive`.
    static func buildSegments(
        from chunks: [TranscriptChunk],
        meetingId: UUID
    ) -> [TranscriptSegment] {
        // Filter to only chunks that belong to this meeting.
        let meetingChunks = chunks.filter { $0.meetingId == meetingId }
        guard !meetingChunks.isEmpty else { return [] }

        var segments: [TranscriptSegment] = []
        var seqCounter = 0

        // Process mic and participant independently, then merge by timestamp.
        let micChunks         = meetingChunks.filter { $0.speaker == "mic" }
                                             .sorted { $0.timestamp < $1.timestamp }
        let participantChunks = meetingChunks.filter { $0.speaker == "participant" }
                                             .sorted { $0.timestamp < $1.timestamp }

        func processChunks(
            _ speakerChunks: [TranscriptChunk],
            source: String,
            speakerLabel: String,
            prefix: String
        ) {
            var previousRaw = ""
            for chunk in speakerChunks {
                let raw   = stripSpeakerPrefix(chunk.text, prefix: prefix)
                let delta = computeDelta(from: previousRaw, to: raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !delta.isEmpty {
                    segments.append(TranscriptSegment(
                        meetingId:     meetingId,
                        timestamp:     chunk.timestamp,
                        source:        source,
                        speakerLabel:  speakerLabel,
                        text:          delta,
                        sequenceIndex: seqCounter
                    ))
                    seqCounter += 1
                }
                previousRaw = raw
            }
        }

        processChunks(micChunks,         source: "mic",         speakerLabel: "Me",          prefix: "Me: ")
        processChunks(participantChunks, source: "participant", speakerLabel: "Participant", prefix: "Participant: ")

        return segments.sorted {
            if $0.timestamp == $1.timestamp { return $0.sequenceIndex < $1.sequenceIndex }
            return $0.timestamp < $1.timestamp
        }
    }

    /// Merge consecutive same-speaker segments that are not interrupted by the
    /// other speaker and fall within `windowSeconds` of each other.
    ///
    /// This produces readable multi-sentence speech blocks rather than many
    /// tiny fragments.
    static func mergeConsecutive(
        _ segments: [TranscriptSegment],
        windowSeconds: TimeInterval = 20
    ) -> [TranscriptSegment] {
        guard segments.count > 1 else { return segments }

        var result: [TranscriptSegment] = []
        // pending accumulator
        var pendingSource:    String    = ""
        var pendingLabel:     String    = ""
        var pendingText:      String    = ""
        var pendingTimestamp: Date      = Date()
        var pendingMeetingId: UUID      = UUID()
        var pendingSeqIndex:  Int       = 0
        var hasPending = false

        for segment in segments {
            guard hasPending else {
                // First segment — start pending
                pendingSource    = segment.source
                pendingLabel     = segment.speakerLabel
                pendingText      = segment.text
                pendingTimestamp = segment.timestamp
                pendingMeetingId = segment.meetingId
                pendingSeqIndex  = segment.sequenceIndex
                hasPending = true
                continue
            }

            let timeDiff = segment.timestamp.timeIntervalSince(pendingTimestamp)

            if segment.source == pendingSource && timeDiff <= windowSeconds {
                // Same speaker within window: merge
                pendingText = (pendingText + " " + segment.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Different speaker or outside window: flush pending, start new
                result.append(TranscriptSegment(
                    meetingId:     pendingMeetingId,
                    timestamp:     pendingTimestamp,
                    source:        pendingSource,
                    speakerLabel:  pendingLabel,
                    text:          pendingText,
                    sequenceIndex: pendingSeqIndex
                ))
                pendingSource    = segment.source
                pendingLabel     = segment.speakerLabel
                pendingText      = segment.text
                pendingTimestamp = segment.timestamp
                pendingMeetingId = segment.meetingId
                pendingSeqIndex  = segment.sequenceIndex
            }
        }

        // Flush final pending
        if hasPending && !pendingText.isEmpty {
            result.append(TranscriptSegment(
                meetingId:     pendingMeetingId,
                timestamp:     pendingTimestamp,
                source:        pendingSource,
                speakerLabel:  pendingLabel,
                text:          pendingText,
                sequenceIndex: pendingSeqIndex
            ))
        }

        return result
    }

    // MARK: - Formatted output for AI analysis

    /// Formats a timeline as a human-readable string for AI analysis.
    ///
    /// Produces the interleaved conversation format:
    /// ```
    /// [00:00] Me: Hello everyone.
    /// [00:10] Participant: Good morning.
    /// [00:18] Me: Let's get started.
    /// ```
    ///
    /// - Parameter segments: Timeline segments, sorted by timestamp.
    /// - Parameter meetingStart: The meeting's start date for offset calculation.
    ///   When `nil`, wall-clock time is used instead.
    static func formatted(
        _ segments: [TranscriptSegment],
        meetingStart: Date? = nil
    ) -> String {
        segments.map { segment in
            let offset = timeOffset(of: segment.timestamp, from: meetingStart)
            return "[\(offset)] \(segment.speakerLabel): \(segment.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Private helpers

    /// Strips a known speaker prefix (e.g. "Me: ") from labeled chunk text.
    private static func stripSpeakerPrefix(_ text: String, prefix: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// Returns the incremental delta from `previous` to `current`.
    ///
    /// SFSpeechRecognizer accumulates text: "Hello" → "Hello everyone" → "Hello everyone let's".
    /// The delta from "Hello everyone" to "Hello everyone let's" is "let's".
    ///
    /// When `current` does NOT start with `previous` (due to SFSpeechRecognizer revisions
    /// e.g. punctuation/capitalisation), returns `current` in full — the revision is treated
    /// as new content.
    static func computeDelta(from previous: String, to current: String) -> String {
        guard !previous.isEmpty else { return current }
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Revision: return the whole current text (best-effort)
        return current
    }

    /// Returns "MM:SS" offset of `date` from `reference`, or "HH:MM" if ≥ 1 hour.
    private static func timeOffset(of date: Date, from reference: Date?) -> String {
        guard let start = reference else {
            let cal = Calendar.current
            let c   = cal.dateComponents([.hour, .minute, .second], from: date)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        let s  = max(0, Int(date.timeIntervalSince(start)))
        let h  = s / 3600
        let m  = (s % 3600) / 60
        let ss = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, ss) }
        return String(format: "%02d:%02d", m, ss)
    }
}
