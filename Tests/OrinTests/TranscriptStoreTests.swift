import XCTest
import SwiftData
@testable import Orin

// MARK: - TranscriptStore unit tests

/// Tests for ``TranscriptStore`` covering every invariant documented in the type header.
///
/// ## Design constraints
///
/// `TranscriptStore` is `@MainActor`-isolated, so the test class is also declared
/// `@MainActor`.  All assertions run on the main actor, satisfying Swift 6 strict
/// concurrency checks.
///
/// ## SwiftData / ModelContext
///
/// Tests that exercise persistence use an **in-memory** `ModelContainer` so they
/// require no disk I/O and are hermetic across CI machines.
///
/// ## UserDefaults isolation
///
/// Orphan-recovery tests write to `UserDefaults.standard`.  Each such test is
/// responsible for cleaning up the keys it sets (`orin.transcript.orphanMeetingID`
/// and `orin.transcript.orphanText`) to avoid cross-test pollution.
@MainActor
final class TranscriptStoreTests: XCTestCase {

    // MARK: - Shared infrastructure

    /// Single shared instance — avoids SFSpeechRecognizer dealloc races and keeps tests fast.
    private static let sharedStore = TranscriptStore()
    private var store: TranscriptStore { Self.sharedStore }

    private static var sharedContainer: ModelContainer = {
        let schema = Schema([MeetingItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: config)
    }()

    private var ctx: ModelContext { Self.sharedContainer.mainContext }

    /// Returns a fresh in-memory `MeetingItem` inserted into `ctx`.
    private func makeMeeting(transcript: String = "") -> MeetingItem {
        let m = MeetingItem(title: "Test Meeting \(UUID().uuidString)", date: Date())
        m.transcript = transcript
        ctx.insert(m)
        try? ctx.save()
        return m
    }

    override func setUp() {
        store._testReset()
    }

    override func tearDown() {
        store._testReset()
    }

    // MARK: - Merge logic

    func testMergeBothEmpty() {
        XCTAssertEqual(TranscriptStore.mergeTranscripts(mic: "", participant: ""), "")
    }

    func testMergeMicOnly() {
        let result = TranscriptStore.mergeTranscripts(mic: "Me: hello", participant: "")
        XCTAssertEqual(result, "Me: hello")
    }

    func testMergeParticipantOnly() {
        let result = TranscriptStore.mergeTranscripts(mic: "", participant: "Participant: world")
        XCTAssertEqual(result, "Participant: world")
    }

    func testMergeBothNonEmpty() {
        let result = TranscriptStore.mergeTranscripts(mic: "Me: hi", participant: "Participant: hey")
        XCTAssertEqual(result, "Me: hi\n\nParticipant: hey")
    }

    // MARK: - Initial state

    func testInitialLiveTranscriptIsEmpty() {
        XCTAssertEqual(store.liveTranscript, "")
    }

    func testInitialPersistedLengthIsZero() {
        XCTAssertEqual(store.persistedLength, 0)
    }

    func testInitialActiveMeetingIDIsNil() {
        XCTAssertNil(store.activeMeetingID)
    }

    // MARK: - beginSession

    func testBeginSessionSetsActiveMeetingID() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        XCTAssertEqual(store.activeMeetingID, m.id)
    }

    func testBeginSessionClearsLiveTranscript() {
        store._testUpdateMic("stale data")
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        XCTAssertEqual(store.liveTranscript, "")
    }

    func testBeginSessionIdempotentSameMeeting() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store.beginSession(meetingID: m.id, meeting: m, context: ctx) // second call — no-op
        XCTAssertEqual(store.activeMeetingID, m.id)
    }

    func testBeginSessionIgnoresDifferentMeetingWhenAlreadyActive() {
        let m1 = makeMeeting()
        let m2 = makeMeeting()
        store.beginSession(meetingID: m1.id, meeting: m1, context: ctx)
        store.beginSession(meetingID: m2.id, meeting: m2, context: ctx) // collision — ignored
        XCTAssertEqual(store.activeMeetingID, m1.id, "Second beginSession with different ID must be ignored")
    }

    func testBeginSessionWritesOrphanKeys() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        let storedID = UserDefaults.standard.string(forKey: "orin.transcript.orphanMeetingID")
        XCTAssertEqual(storedID, m.id.uuidString)
    }

    func testBeginSessionPreservesExistingTranscriptAsBaseline() {
        let m = makeMeeting(transcript: "Existing content")
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        XCTAssertEqual(store.persistedLength, "Existing content".count,
                       "persistedLength must reflect the meeting's existing transcript on session start")
    }

    // MARK: - updateMic / updateParticipant — empty-overwrite protection

    func testUpdateMicSetsLiveTranscript() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store.updateMic("Me: hello world")
        XCTAssertEqual(store.liveTranscript, "Me: hello world")
    }

    func testUpdateMicEmptyDoesNotClearExistingContent() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store.updateMic("Me: some content")
        store.updateMic("")  // empty — must NOT clear
        XCTAssertEqual(store.liveTranscript, "Me: some content",
                       "Empty updateMic must not overwrite non-empty liveTranscript")
    }

    func testUpdateParticipantSetsLiveTranscript() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store.updateParticipant("Participant: yes")
        XCTAssertEqual(store.liveTranscript, "Participant: yes")
    }

    func testUpdateParticipantEmptyDoesNotClearExistingContent() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store.updateParticipant("Participant: hello")
        store.updateParticipant("")  // empty — must NOT clear
        XCTAssertEqual(store.liveTranscript, "Participant: hello",
                       "Empty updateParticipant must not overwrite non-empty liveTranscript")
    }

    func testUpdateMicOutsideSessionIsNoop() {
        // No beginSession — store has no activeMeetingID.
        store._testUpdateMic("This should not appear") // _test variant bypasses session guard
        // The test variant bypasses the session guard; use it to confirm recompute does run.
        // The public updateMic with no session must simply not touch liveTranscript.
        // We confirm via the public API:
        store.updateMic("should be ignored")
        // liveTranscript will reflect _testUpdateMic since that bypasses the guard; just
        // verify the public API after a full reset.
        store._testReset()
        store.updateMic("ignored")
        XCTAssertEqual(store.liveTranscript, "",
                       "updateMic outside a session must be a no-op")
    }

    // MARK: - recomputeLive merge

    func testBothStreamsProduceMergedTranscript() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store.updateMic("Me: greetings")
        store.updateParticipant("Participant: hi there")
        XCTAssertEqual(store.liveTranscript, "Me: greetings\n\nParticipant: hi there")
    }

    func testRecomputeLiveDoesNotClearOnEmptyMerge() {
        // Inject directly via test hooks (no session guard)
        store._testUpdateMic("Me: content")
        // Now wipe mic via test hook (simulates empty result) — should not clear liveTranscript
        // because both result in empty merged string but liveTranscript is non-empty.
        // The guard in recomputeLive prevents overwrite.
        let before = store.liveTranscript
        store._testUpdateMic("")
        XCTAssertEqual(store.liveTranscript, before,
                       "recomputeLive must not overwrite non-empty liveTranscript with empty merge")
    }

    // MARK: - checkpoint

    func testCheckpointWithNoSessionIsNoop() {
        // No crash, no state change.
        store.checkpoint()
        XCTAssertEqual(store.persistedLength, 0)
    }

    func testCheckpointWithEmptyLiveTranscriptIsNoop() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store.checkpoint()  // liveTranscript is "" — must skip
        XCTAssertEqual(store.persistedLength, 0)
    }

    func testCheckpointPersistsAndUpdatesPersistedLength() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store._testUpdateMic("Me: checkpoint test content")
        store.checkpoint()
        XCTAssertGreaterThan(store.persistedLength, 0,
                              "persistedLength must be > 0 after a successful checkpoint")
        XCTAssertEqual(store.persistedLength, store.liveTranscript.count)
    }

    func testCheckpointDoesNotSaveWhenNoGrowth() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store._testUpdateMic("Me: some text")
        store.checkpoint()
        let lengthAfterFirst = store.persistedLength
        store.checkpoint()  // no new content — must skip
        XCTAssertEqual(store.persistedLength, lengthAfterFirst,
                       "Second checkpoint with identical content must not update persistedLength")
    }

    func testCheckpointUpdatesMeetingTranscript() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store._testUpdateMic("Me: saved to model")
        store.checkpoint()
        XCTAssertEqual(m.transcript, "Me: saved to model",
                       "Checkpoint must write liveTranscript to the meeting model")
    }

    func testCheckpointUpdatesOrphanKey() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store._testUpdateMic("Me: orphan content")
        store.checkpoint()
        let orphanText = UserDefaults.standard.string(forKey: "orin.transcript.orphanText")
        XCTAssertEqual(orphanText, store.liveTranscript,
                       "Checkpoint must keep orphan UserDefaults key current")
    }

    // MARK: - finalize — idempotency

    func testFinalizeWithNoActiveSessionIsNoop() async {
        // Must not crash and must not affect any state.
        await store.finalize(elapsed: 60, audioURL: nil)
        XCTAssertNil(store.activeMeetingID)
    }

    func testFinalizeIdempotentConcurrentCalls() async {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store._testUpdateMic("Me: final text")

        // Two concurrent finalize calls — first should finalize, second should no-op.
        async let first: () = store.finalize(elapsed: 30, audioURL: nil)
        async let second: () = store.finalize(elapsed: 30, audioURL: nil)
        await first
        await second

        // No crash; activeMeetingID should be nil.
        XCTAssertNil(store.activeMeetingID)
    }

    // MARK: - finalize — best-of-N transcript selection

    func testFinalizePicksLongestCandidate() async {
        let m = makeMeeting(transcript: "short")
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        // Inject a longer transcript via test hook
        store._testUpdateMic("Me: this is a much longer transcript than short")
        await store.finalize(elapsed: 45, audioURL: nil)
        XCTAssertGreaterThan(m.transcript.count, "short".count,
                              "finalize must select the longest candidate (liveTranscript > model)")
    }

    func testFinalizePreservesModelTranscriptWhenLiveIsEmpty() async {
        let m = makeMeeting(transcript: "Pre-existing transcript content")
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        // Don't inject any live text — all candidates will be empty except the model value.
        await store.finalize(elapsed: 10, audioURL: nil)
        XCTAssertEqual(m.transcript, "Pre-existing transcript content",
                       "finalize must not replace a valid model transcript when all live candidates are empty")
    }

    func testFinalizeNeverTruncatesModelTranscript() async {
        let longText = String(repeating: "word ", count: 200)
        let m = makeMeeting(transcript: longText)
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        // Inject a shorter transcript — integrity rule must prefer the longer model value.
        store._testUpdateMic("Me: short")
        await store.finalize(elapsed: 5, audioURL: nil)
        XCTAssertGreaterThanOrEqual(m.transcript.count, longText.count,
                                     "Integrity rule: finalize must never truncate a longer model transcript")
    }

    func testFinalizeSetsDurationSeconds() async {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        await store.finalize(elapsed: 120, audioURL: nil)
        XCTAssertEqual(m.durationSeconds, 120,
                       "finalize must persist the elapsed recording duration")
    }

    func testFinalizeSetAudioFilePath() async {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        let url = URL(fileURLWithPath: "/tmp/orin-test-recording.caf")
        await store.finalize(elapsed: 60, audioURL: url)
        XCTAssertEqual(m.audioFilePath, url.path,
                       "finalize must persist the audio file path")
    }

    func testFinalizeDoesNotSetAudioFilePathWhenNil() async {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        m.audioFilePath = nil
        await store.finalize(elapsed: 30, audioURL: nil)
        XCTAssertNil(m.audioFilePath,
                     "finalize must not set audioFilePath when audioURL is nil")
    }

    func testFinalizeEndsSession() async {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        await store.finalize(elapsed: 20, audioURL: nil)
        XCTAssertNil(store.activeMeetingID,
                     "finalize must clear activeMeetingID — session must be ended")
        XCTAssertNil(store._testActiveMeeting,
                     "finalize must nil the internal activeMeeting reference")
    }

    func testFinalizeRemovesOrphanKeys() async {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store._testUpdateMic("Me: will be cleared")
        store.checkpoint()
        await store.finalize(elapsed: 30, audioURL: nil)
        XCTAssertNil(UserDefaults.standard.string(forKey: "orin.transcript.orphanMeetingID"),
                     "finalize must remove the orphan meeting ID key")
        XCTAssertNil(UserDefaults.standard.string(forKey: "orin.transcript.orphanText"),
                     "finalize must remove the orphan text key")
    }

    // MARK: - Session lifecycle

    func testSessionCanBeRestartedAfterFinalize() async {
        let m1 = makeMeeting()
        store.beginSession(meetingID: m1.id, meeting: m1, context: ctx)
        await store.finalize(elapsed: 10, audioURL: nil)

        let m2 = makeMeeting()
        store.beginSession(meetingID: m2.id, meeting: m2, context: ctx)
        XCTAssertEqual(store.activeMeetingID, m2.id,
                       "A new session must be startable after finalize completes")
    }

    func testResetClearsAllState() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store._testUpdateMic("Me: some content")
        store._testReset()
        XCTAssertNil(store.activeMeetingID)
        XCTAssertEqual(store.liveTranscript, "")
        XCTAssertEqual(store.persistedLength, 0)
        XCTAssertNil(store._testActiveMeeting)
        XCTAssertEqual(store._testLastPersistedText, "")
    }

    // MARK: - Orphan recovery

    func testRecoverOrphanRestoresLongerText() {
        let m = makeMeeting(transcript: "short")
        let longerText = "This is the orphan text that is much longer than the model"
        UserDefaults.standard.set(m.id.uuidString, forKey: "orin.transcript.orphanMeetingID")
        UserDefaults.standard.set(longerText, forKey: "orin.transcript.orphanText")

        store.recoverOrphan(in: ctx)

        XCTAssertEqual(m.transcript, longerText,
                       "recoverOrphan must restore the orphan text when it is longer than the model")

        // Keys must be cleared after recovery regardless of outcome.
        XCTAssertNil(UserDefaults.standard.string(forKey: "orin.transcript.orphanMeetingID"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "orin.transcript.orphanText"))
    }

    func testRecoverOrphanSkipsWhenModelIsLonger() {
        let existingText = String(repeating: "already long content ", count: 20)
        let m = makeMeeting(transcript: existingText)
        let shorterOrphan = "short orphan"
        UserDefaults.standard.set(m.id.uuidString, forKey: "orin.transcript.orphanMeetingID")
        UserDefaults.standard.set(shorterOrphan, forKey: "orin.transcript.orphanText")

        store.recoverOrphan(in: ctx)

        XCTAssertEqual(m.transcript, existingText,
                       "recoverOrphan must not overwrite a longer model transcript with a shorter orphan")
        XCTAssertNil(UserDefaults.standard.string(forKey: "orin.transcript.orphanMeetingID"))
    }

    func testRecoverOrphanClearsStaleKeyWhenMeetingNotFound() {
        // Write a meeting ID that doesn't exist in the store.
        let staleID = UUID()
        UserDefaults.standard.set(staleID.uuidString, forKey: "orin.transcript.orphanMeetingID")
        UserDefaults.standard.set("some text", forKey: "orin.transcript.orphanText")

        store.recoverOrphan(in: ctx)  // must not crash

        XCTAssertNil(UserDefaults.standard.string(forKey: "orin.transcript.orphanMeetingID"),
                     "Stale orphan key for a missing meeting must be cleared")
        XCTAssertNil(UserDefaults.standard.string(forKey: "orin.transcript.orphanText"))
    }

    func testRecoverOrphanIsNoopWhenNoKeysPresent() {
        // Ensure keys are absent.
        UserDefaults.standard.removeObject(forKey: "orin.transcript.orphanMeetingID")
        UserDefaults.standard.removeObject(forKey: "orin.transcript.orphanText")

        // Must not crash.
        store.recoverOrphan(in: ctx)
        XCTAssertNil(store.activeMeetingID)
    }

    func testRecoverOrphanSkipsEmptyOrphanText() {
        let m = makeMeeting(transcript: "existing")
        UserDefaults.standard.set(m.id.uuidString, forKey: "orin.transcript.orphanMeetingID")
        UserDefaults.standard.set("", forKey: "orin.transcript.orphanText")

        store.recoverOrphan(in: ctx)

        XCTAssertEqual(m.transcript, "existing",
                       "recoverOrphan must not overwrite with an empty orphan text")
    }

    // MARK: - testLastPersistedText

    func testLastPersistedTextUpdatesOnCheckpoint() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        store._testUpdateMic("Me: persisted text")
        store.checkpoint()
        XCTAssertEqual(store._testLastPersistedText, store.liveTranscript,
                       "_testLastPersistedText must mirror liveTranscript after checkpoint")
    }

    func testLastPersistedTextIsEmptyBeforeAnyCheckpoint() {
        let m = makeMeeting()
        store.beginSession(meetingID: m.id, meeting: m, context: ctx)
        XCTAssertEqual(store._testLastPersistedText, "",
                       "_testLastPersistedText must be empty at session start (no prior checkpoint)")
    }
}
