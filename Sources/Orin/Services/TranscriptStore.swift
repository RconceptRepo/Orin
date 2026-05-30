import Foundation
import OSLog
import Observation
import SwiftData

// MARK: - TranscriptStore

/// Central coordinator for the end-to-end transcript lifecycle.
///
/// `TranscriptStore` is the **single source of truth** for transcript state
/// during and after a recording session.  It replaces the distributed, view-level
/// persistence that was scattered across `MainContainerView` and `MeetingDetailView`.
///
/// # Data flow
///
/// ```
/// RecordingService.speakerTranscript ("Me: …")
///       ↓  updateMic()
/// SystemAudioCaptureService.participantSpeakerTranscript ("Participant: …")
///       ↓  updateParticipant()
/// TranscriptStore.liveTranscript  (integrity-guarded, merged)
///       ↓  checkpoint() every 3 s + on every UserDefaults backup
/// MeetingItem.transcript  (SwiftData in-memory model)
///       ↓  safeSaveWithRetry()
/// SQLite store (durable on-disk)
/// ```
///
/// # Integrity rules (enforced at every write)
///
/// 1. **Empty-overwrite**: empty text never replaces non-empty text.
/// 2. **Truncation**: shorter text never replaces longer text in the model.
/// 3. **Best-of-N finalization**: finalize() picks the longest available
///    transcript from {fresh, snapshot, last-persisted, model}.
///
/// # Orphan recovery
///
/// `beginSession` writes `(meetingID, latestText)` to `UserDefaults`.
/// `recoverOrphan(in:)` detects an unfinished session on relaunch and
/// restores the checkpoint text to the meeting model if it is longer
/// than what was last successfully persisted.
///
/// # Thread safety
///
/// `TranscriptStore` is `@MainActor`-isolated.  All public methods must be
/// called from the main actor.  The checkpoint timer uses
/// `Task { @MainActor in }` to satisfy macOS 26 executor-isolation checks.
@MainActor
@Observable
final class TranscriptStore: Service {

    // MARK: - Public observable state

    /// Current merged, speaker-labeled transcript for the active session.
    /// Updated synchronously on every `updateMic` / `updateParticipant` call.
    /// Views bind their live display to this property.
    private(set) var liveTranscript = ""

    /// Character count at the most recent successful SwiftData save.
    /// Views or tests can poll this to verify persistence progress.
    private(set) var persistedLength = 0

    /// Meeting ID being recorded (`nil` between sessions).
    private(set) var activeMeetingID: UUID?

    /// Wall-clock time of the most recent `updateMic` or `updateParticipant`
    /// call that produced new content.  Used by the auto-stop watchdog to
    /// determine audio inactivity: if this is nil or older than the configured
    /// threshold, the mic/system audio are considered silent.
    private(set) var lastUpdateTime: Date?

    /// Seconds since the most recent audio update, or `nil` if no update has
    /// occurred in this session.
    var secondsSinceLastUpdate: TimeInterval? {
        lastUpdateTime.map { Date().timeIntervalSince($0) }
    }

    // MARK: - Private — in-memory buffers

    /// Latest speaker-labeled mic text, e.g. "Me: hello world".
    /// Updated via `updateMic`; never replaced by empty string.
    @ObservationIgnored private var micLabeledText = ""

    /// Latest speaker-labeled participant text, e.g. "Participant: thanks".
    @ObservationIgnored private var participantLabeledText = ""

    /// Text of the most recently persisted checkpoint; used as one of the
    /// finalization candidates so a crashed-and-relaunched flow can still recover.
    @ObservationIgnored private var lastPersistedText = ""

    // MARK: - Private — SwiftData references

    /// Strong reference to the meeting being recorded.
    /// Held from `beginSession` until `endSession` so the checkpoint timer
    /// can save without requiring a `modelContext.fetch` on every tick.
    @ObservationIgnored private var activeMeeting: MeetingItem?
    @ObservationIgnored private var activeContext: ModelContext?

    // MARK: - Private — checkpoint timer

    @ObservationIgnored private nonisolated(unsafe) var checkpointTimer: Timer?

    // MARK: - Orphan-recovery UserDefaults keys

    private let kOrphanMeetingID = "orin.transcript.orphanMeetingID"
    private let kOrphanText      = "orin.transcript.orphanText"

    // MARK: - Logging

    private let log = Logger(subsystem: "com.clavrit.orin", category: "TranscriptStore")

    // MARK: - Session lifecycle

    /// Starts a new transcript session.
    ///
    /// Idempotent: if a session is already active for the same meeting, this is
    /// a no-op.  If a different meeting is somehow active, logs a warning and
    /// returns without overwriting the in-flight session.
    ///
    /// - Parameters:
    ///   - meetingID: The ID of the `MeetingItem` being recorded.
    ///   - meeting: The SwiftData model — held directly for checkpoint saves.
    ///   - context: The `ModelContext` used for all saves within this session.
    func beginSession(meetingID: UUID, meeting: MeetingItem, context: ModelContext) {
        if let existing = activeMeetingID {
            if existing == meetingID {
                log.debug("beginSession: session already active for \(meetingID) — no-op")
            } else {
                log.warning("beginSession: collision — active=\(existing) new=\(meetingID) — ignoring new call")
            }
            return
        }

        log.info("session begin meetingID=\(meetingID) existingTranscriptChars=\(meeting.transcript.count)")

        activeMeetingID    = meetingID
        activeMeeting      = meeting
        activeContext      = context
        micLabeledText     = ""
        participantLabeledText = ""
        liveTranscript     = ""
        lastPersistedText  = meeting.transcript  // preserve existing content as baseline
        persistedLength    = meeting.transcript.count

        // Orphan-recovery keys (written on crash, cleaned on finalize)
        UserDefaults.standard.set(meetingID.uuidString, forKey: kOrphanMeetingID)
        if !meeting.transcript.isEmpty {
            UserDefaults.standard.set(meeting.transcript, forKey: kOrphanText)
        }

        startCheckpointTimer()
    }

    /// Tears down all session state.  Called from `finalize` after the terminal save.
    ///
    /// Clears orphan-recovery keys, stops the checkpoint timer, and nil-s the
    /// meeting/context references.
    private func endSession() {
        stopCheckpointTimer()
        activeMeetingID = nil
        activeMeeting   = nil
        activeContext   = nil
        UserDefaults.standard.removeObject(forKey: kOrphanMeetingID)
        UserDefaults.standard.removeObject(forKey: kOrphanText)
        log.info("session ended")
    }

    // MARK: - Transcript updates (called from view onChange handlers)

    // Minimum character growth to trigger an immediate TranscriptChunk write.
    // Prevents write storms from rapid SFSpeechRecognizer partial results
    // while still persisting meaningful increments between 3-second checkpoints.
    private static let chunkWriteThreshold = 10

    /// Applies the latest speaker-labeled mic transcript chunk.
    ///
    /// **Empty-overwrite rule**: if `labeledText` is empty and the buffer
    /// already contains content, the update is silently discarded.  This
    /// prevents the `RecordingService.transcript = ""` reset that fires at
    /// `startRecording()` from clearing a meeting's existing transcript.
    ///
    /// **TranscriptChunk persistence**: when content grows by ≥ 10 characters
    /// vs. the last mic chunk, a `TranscriptChunk` is written to SwiftData
    /// immediately (not waiting for the 3-second checkpoint timer).
    func updateMic(_ labeledText: String) {
        guard activeMeetingID != nil else { return }
        guard !labeledText.isEmpty || micLabeledText.isEmpty else {
            log.debug("updateMic skipped — empty chunk, micChars=\(self.micLabeledText.count) protected")
            return
        }
        let previousLength = micLabeledText.count
        micLabeledText = labeledText
        log.debug("updateMic micChars=\(labeledText.count)")
        recomputeLive()
        lastUpdateTime = Date()
        persistChunkIfNeeded(speaker: "mic", text: labeledText, previousLength: previousLength)
    }

    /// Applies the latest speaker-labeled participant transcript chunk.
    ///
    /// Same empty-overwrite rule as `updateMic`.
    func updateParticipant(_ labeledText: String) {
        guard activeMeetingID != nil else { return }
        guard !labeledText.isEmpty || participantLabeledText.isEmpty else {
            log.debug("updateParticipant skipped — empty chunk, participantChars=\(self.participantLabeledText.count) protected")
            return
        }
        let previousLength = participantLabeledText.count
        participantLabeledText = labeledText
        log.debug("updateParticipant participantChars=\(labeledText.count)")
        recomputeLive()
        lastUpdateTime = Date()
        persistChunkIfNeeded(speaker: "participant", text: labeledText, previousLength: previousLength)
    }

    /// Writes a `TranscriptChunk` to SwiftData when content has grown by at
    /// least `chunkWriteThreshold` characters since the last chunk.
    ///
    /// This provides crash-safe granular persistence between 3-second checkpoints.
    private func persistChunkIfNeeded(speaker: String, text: String, previousLength: Int) {
        guard let meeting = activeMeeting,
              let context = activeContext,
              text.count - previousLength >= Self.chunkWriteThreshold else { return }
        let chunk = TranscriptChunk(meetingId: meeting.id, speaker: speaker, text: text)
        context.insert(chunk)
        do {
            try context.save()
        } catch {
            log.warning("TranscriptChunk save failed (non-fatal): \(error)")
        }
        log.debug("TranscriptChunk written speaker=\(speaker) chars=\(text.count)")
    }

    // MARK: - Persistence

    /// Persists `liveTranscript` to the active meeting model if the transcript
    /// has grown since the last save.
    ///
    /// Called automatically by the 3-second checkpoint timer.  Also callable
    /// on-demand (e.g., from `applicationWillTerminate`).
    func checkpoint() {
        guard let meeting = activeMeeting, let context = activeContext else {
            log.debug("checkpoint: no active session — skipped")
            return
        }
        guard !liveTranscript.isEmpty else {
            log.debug("checkpoint: empty live transcript — skipped")
            return
        }
        guard liveTranscript.count > persistedLength else {
            log.debug("checkpoint: no growth (live=\(self.liveTranscript.count) persisted=\(self.persistedLength)) — skipped")
            return
        }

        let text = liveTranscript
        meeting.transcript = text
        context.safeSaveWithRetry(context: "transcript checkpoint")
        lastPersistedText = text
        persistedLength   = text.count

        // Keep orphan backup current
        UserDefaults.standard.set(text, forKey: kOrphanText)
        log.info("checkpoint saved chars=\(text.count) elapsed=\(meeting.durationSeconds)s")
    }

    /// Finalises the recording session.
    ///
    /// **Idempotent**: clears `activeMeetingID` at entry so concurrent calls
    /// (e.g., from both `MainContainerView` and `MeetingDetailView`) only execute
    /// once — subsequent calls return immediately.
    ///
    /// Algorithm:
    /// 1. Capture a transcript snapshot BEFORE the 1.5 s sleep (guards against a
    ///    new recording session starting and resetting the recognition service).
    /// 2. After sleep, compare fresh vs. snapshot vs. last-persisted vs. model value.
    /// 3. Select the longest non-empty candidate (best-of-N).
    /// 4. Integrity check: never write a shorter string than what is already in the model.
    /// 5. Save with retry; verify post-save length.
    /// 6. Call `endSession()` to release resources and clear orphan keys.
    func finalize(elapsed: TimeInterval, audioURL: URL?) async {
        guard activeMeetingID != nil else {
            log.debug("finalize: no active session — returning (idempotent)")
            return
        }

        // Clear activeMeetingID immediately — prevents concurrent finalize calls
        // from entering past this guard (they're still on @MainActor so this is safe).
        let meetingIDForLog = activeMeetingID
        activeMeetingID = nil

        guard let meeting = activeMeeting, let context = activeContext else {
            log.warning("finalize: activeMeeting/activeContext nil — session cleaned up without save")
            endSession()
            return
        }

        log.info("finalize begin meetingID=\(String(describing: meetingIDForLog)) — waiting 1.5 s for trailing recognition chunks")
        stopCheckpointTimer()

        // Snapshot state BEFORE sleep (protects against a new recording session
        // starting within the 1.5 s window and resetting RecordingService.transcript)
        let snapshotLive      = liveTranscript
        let snapshotPersisted = lastPersistedText
        let snapshotModel     = meeting.transcript

        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // After sleep: re-read live (recognition may have delivered a final chunk)
        let freshLive = liveTranscript

        // Best-of-N: pick the longest non-empty transcript
        let candidates = [freshLive, snapshotLive, snapshotPersisted, snapshotModel]
            .filter { !$0.isEmpty }
        let finalText = candidates.max(by: { $0.count < $1.count }) ?? ""

        log.info("finalize candidates: fresh=\(freshLive.count) snapshot=\(snapshotLive.count) persisted=\(snapshotPersisted.count) model=\(snapshotModel.count) → selected=\(finalText.count)")

        // Integrity: never truncate the model (write only if longer or equal)
        if finalText.isEmpty {
            log.warning("finalize: all candidates empty — model transcript preserved as-is (\(meeting.transcript.count) chars)")
        } else if finalText.count >= meeting.transcript.count {
            meeting.transcript = finalText
            log.info("finalize: transcript updated chars=\(finalText.count)")
        } else {
            log.warning("finalize: INTEGRITY — finalText(\(finalText.count)) shorter than model(\(meeting.transcript.count)) — keeping model value")
        }

        meeting.durationSeconds = elapsed
        if let url = audioURL { meeting.audioFilePath = url.path }

        let preSaveLen = meeting.transcript.count
        context.safeSaveWithRetry(context: "meeting recording final")
        let postSaveLen = meeting.transcript.count

        if postSaveLen < preSaveLen {
            log.error("INTEGRITY WARNING: post-save len \(postSaveLen) < pre-save \(preSaveLen) — SwiftData serialisation issue")
        } else {
            log.info("finalize complete chars=\(postSaveLen) duration=\(elapsed)s audioURL=\(audioURL?.lastPathComponent ?? "nil")")
        }

        // Build conversation timeline from TranscriptChunks.
        // Captures the meeting ID before endSession() clears activeMeeting.
        buildTimelineSegments(for: meeting, context: context)

        endSession()
    }

    // MARK: - Conversation timeline

    /// Fetches all `TranscriptChunk` records for `meeting`, builds `TranscriptSegment`
    /// values via `ConversationTimelineBuilder`, and inserts them into `context`.
    ///
    /// Called at the end of `finalize()` — after the transcript string is committed —
    /// so all chunks written during the session are available.
    ///
    /// Idempotent when chunks exist but segments are already present: segments are
    /// built and inserted fresh each time (duplicate detection is left to the caller
    /// if re-finalization ever occurs).
    ///
    /// No-op when no chunks exist (e.g., very short recordings or first-run without chunks).
    private func buildTimelineSegments(for meeting: MeetingItem, context: ModelContext) {
        let meetingID = meeting.id

        var chunkDescriptor = FetchDescriptor<TranscriptChunk>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        chunkDescriptor.fetchLimit = 10_000  // guard against runaway fetches

        guard let allChunks = try? context.fetch(chunkDescriptor) else {
            log.warning("timeline: failed to fetch chunks for meetingID=\(meetingID)")
            return
        }

        let chunks = allChunks.filter { $0.meetingId == meetingID }
        guard !chunks.isEmpty else {
            log.debug("timeline: no chunks for meetingID=\(meetingID) — skipping segment build")
            return
        }

        let rawSegments  = ConversationTimelineBuilder.buildSegments(from: chunks, meetingId: meetingID)
        let merged       = ConversationTimelineBuilder.mergeConsecutive(rawSegments)

        guard !merged.isEmpty else {
            log.debug("timeline: no segments produced for meetingID=\(meetingID)")
            return
        }

        for segment in merged { context.insert(segment) }
        do {
            try context.save()
            log.info("timeline: built segments=\(merged.count) from chunks=\(chunks.count) meetingID=\(meetingID)")
        } catch {
            log.warning("timeline: segment save failed (non-fatal): \(error)")
        }
    }

    // MARK: - Orphan recovery

    /// Called once at app launch.  If the previous session was interrupted (crash,
    /// force-quit, SIGKILL), restores the most recent checkpoint text to the
    /// meeting model if it is longer than what was last committed to SQLite.
    ///
    /// Recovery candidates (best-of-N, longest wins):
    /// 1. `UserDefaults` orphan backup (written every 3 s by checkpoint timer)
    /// 2. `TranscriptChunk` records in SwiftData (written on every ≥10-char update)
    ///
    /// - Parameter context: The app's main `ModelContext`.
    func recoverOrphan(in context: ModelContext) {
        guard let idStr    = UserDefaults.standard.string(forKey: kOrphanMeetingID),
              let meetingID = UUID(uuidString: idStr) else { return }

        log.warning("ORPHAN RECOVERY: detected interrupted recording meetingID=\(meetingID)")

        var descriptor = FetchDescriptor<MeetingItem>(
            predicate: #Predicate { $0.id == meetingID }
        )
        descriptor.fetchLimit = 1

        guard let meeting = (try? context.fetch(descriptor))?.first else {
            log.warning("ORPHAN RECOVERY: meetingID=\(meetingID) not found in store — clearing stale keys")
            UserDefaults.standard.removeObject(forKey: kOrphanMeetingID)
            UserDefaults.standard.removeObject(forKey: kOrphanText)
            return
        }

        // --- Candidate 1: UserDefaults backup ---
        let orphanText = UserDefaults.standard.string(forKey: kOrphanText) ?? ""

        // --- Candidate 2: TranscriptChunk reconstruction ---
        let chunkText = rebuildFromChunks(meetingID: meetingID, context: context)

        // Best-of-N: pick the longest non-empty candidate vs. model
        let candidates = [orphanText, chunkText, meeting.transcript]
            .filter { !$0.isEmpty }
        let bestText = candidates.max(by: { $0.count < $1.count }) ?? ""

        let modelChars = meeting.transcript.count
        if bestText.count > modelChars {
            meeting.transcript = bestText
            context.safeSave(context: "orphan transcript recovery")
            log.info("ORPHAN RECOVERY: restored chars=\(bestText.count) (gained \(bestText.count - modelChars)) meeting='\(meeting.title)'")
        } else {
            log.info("ORPHAN RECOVERY: model transcript chars=\(modelChars) sufficient — no restore needed")
        }

        UserDefaults.standard.removeObject(forKey: kOrphanMeetingID)
        UserDefaults.standard.removeObject(forKey: kOrphanText)
        log.info("ORPHAN RECOVERY: complete meeting='\(meeting.title)'")
    }

    /// Reconstructs a transcript from `TranscriptChunk` records for `meetingID`.
    ///
    /// Fetches the most recent "mic" and "participant" chunks and merges them.
    /// Returns `""` if no chunks exist (e.g., meeting just started before first chunk).
    private func rebuildFromChunks(meetingID: UUID, context: ModelContext) -> String {
        let chunkDescriptor = FetchDescriptor<TranscriptChunk>(
            predicate: #Predicate { $0.meetingId == meetingID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        guard let chunks = try? context.fetch(chunkDescriptor), !chunks.isEmpty else {
            return ""
        }
        let latestMic = chunks.first { $0.speaker == "mic" }?.text ?? ""
        let latestParticipant = chunks.first { $0.speaker == "participant" }?.text ?? ""
        let rebuilt = TranscriptStore.mergeTranscripts(mic: latestMic, participant: latestParticipant)
        log.info("ORPHAN RECOVERY: rebuilt from \(chunks.count) chunks → chars=\(rebuilt.count)")
        return rebuilt
    }

    // MARK: - Testing support

#if DEBUG
    /// Directly injects mic text for unit tests (bypasses `activeMeetingID` guard).
    func _testUpdateMic(_ text: String) {
        guard !text.isEmpty || micLabeledText.isEmpty else { return }
        micLabeledText = text
        recomputeLive()
    }

    /// Directly injects participant text for unit tests.
    func _testUpdateParticipant(_ text: String) {
        guard !text.isEmpty || participantLabeledText.isEmpty else { return }
        participantLabeledText = text
        recomputeLive()
    }

    /// Resets all session state; call in test setUp/tearDown.
    func _testReset() {
        stopCheckpointTimer()
        activeMeetingID        = nil
        activeMeeting          = nil
        activeContext          = nil
        micLabeledText         = ""
        participantLabeledText = ""
        liveTranscript         = ""
        lastPersistedText      = ""
        persistedLength        = 0
        lastUpdateTime         = nil
        UserDefaults.standard.removeObject(forKey: kOrphanMeetingID)
        UserDefaults.standard.removeObject(forKey: kOrphanText)
    }

    /// Exposes `lastPersistedText` for assertions.
    var _testLastPersistedText: String { lastPersistedText }

    /// Exposes `activeMeeting` for assertions.
    var _testActiveMeeting: MeetingItem? { activeMeeting }
#endif

    // MARK: - Private helpers

    /// Recomputes `liveTranscript` from the current mic + participant buffers.
    ///
    /// Empty-overwrite rule: if the merged result is empty but `liveTranscript`
    /// already has content, the update is discarded.
    private func recomputeLive() {
        let merged = Self.mergeTranscripts(mic: micLabeledText, participant: participantLabeledText)
        if merged.isEmpty, !liveTranscript.isEmpty {
            log.debug("recomputeLive: skip empty-overwrite (live=\(self.liveTranscript.count) chars)")
            return
        }
        liveTranscript = merged
    }

    static func mergeTranscripts(mic: String, participant: String) -> String {
        switch (mic.isEmpty, participant.isEmpty) {
        case (true,  true):  return ""
        case (false, true):  return mic
        case (true,  false): return participant
        case (false, false): return "\(mic)\n\n\(participant)"
        }
    }

    // MARK: - Checkpoint timer

    private func startCheckpointTimer() {
        stopCheckpointTimer()
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkpoint()
            }
        }
        log.info("checkpoint timer started (3 s interval)")
    }

    private func stopCheckpointTimer() {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
    }

    deinit {
        checkpointTimer?.invalidate()
    }
}
