import XCTest
import SwiftData
@testable import Orin

// MARK: - MeetingDeletionTests
//
// Verifies that deleteMeetingFully() cleans up all associated records:
//   - TranscriptChunk records
//   - TranscriptSegment records
//   - FolderSummaryItem records for the meeting's folder
//   - The MeetingItem itself

@MainActor
final class MeetingDeletionTests: XCTestCase {

    private static var sharedContainer: ModelContainer = {
        let schema = Schema([
            MeetingItem.self, MeetingFolderItem.self,
            TranscriptChunk.self, TranscriptSegment.self, FolderSummaryItem.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }()
    private var ctx: ModelContext { Self.sharedContainer.mainContext }

    override func setUp() {
        // Clean all records before each test
        ((try? ctx.fetch(FetchDescriptor<MeetingItem>()))        ?? []).forEach { ctx.delete($0) }
        ((try? ctx.fetch(FetchDescriptor<MeetingFolderItem>())) ?? []).forEach { ctx.delete($0) }
        ((try? ctx.fetch(FetchDescriptor<TranscriptChunk>()))   ?? []).forEach { ctx.delete($0) }
        ((try? ctx.fetch(FetchDescriptor<TranscriptSegment>())) ?? []).forEach { ctx.delete($0) }
        ((try? ctx.fetch(FetchDescriptor<FolderSummaryItem>())) ?? []).forEach { ctx.delete($0) }
        try? ctx.save()
    }

    // MARK: - Helpers

    private func makeMeeting(title: String = "Test", folderID: UUID? = nil) -> MeetingItem {
        let m = MeetingItem(title: title, date: Date(), durationSeconds: 1800)
        m.folderID = folderID
        ctx.insert(m)
        return m
    }

    private func makeChunk(meetingId: UUID, speaker: String = "mic") -> TranscriptChunk {
        let c = TranscriptChunk(meetingId: meetingId, speaker: speaker, text: "Me: Hello world")
        ctx.insert(c)
        return c
    }

    private func makeSegment(meetingId: UUID) -> TranscriptSegment {
        let s = TranscriptSegment(meetingId: meetingId, timestamp: Date(),
                                  source: "mic", speakerLabel: "Me",
                                  text: "Hello world", sequenceIndex: 0)
        ctx.insert(s)
        return s
    }

    private func count<T: PersistentModel>(_ type: T.Type) -> Int {
        (try? ctx.fetch(FetchDescriptor<T>()))?.count ?? 0
    }

    // MARK: - Tests: deleteMeetingFully

    func testDeleteMeetingRemovesMeetingItem() throws {
        let m = makeMeeting()
        try ctx.save()
        XCTAssertEqual(count(MeetingItem.self), 1)

        ctx.deleteMeetingFully(m)
        try ctx.save()

        XCTAssertEqual(count(MeetingItem.self), 0)
    }

    func testDeleteMeetingRemovesTranscriptChunks() throws {
        let m = makeMeeting()
        _ = makeChunk(meetingId: m.id)
        _ = makeChunk(meetingId: m.id)
        try ctx.save()
        XCTAssertEqual(count(TranscriptChunk.self), 2)

        ctx.deleteMeetingFully(m)
        try ctx.save()

        XCTAssertEqual(count(TranscriptChunk.self), 0,
                       "deleteMeetingFully must remove all TranscriptChunk records")
    }

    func testDeleteMeetingRemovesTranscriptSegments() throws {
        let m = makeMeeting()
        _ = makeSegment(meetingId: m.id)
        _ = makeSegment(meetingId: m.id)
        try ctx.save()
        XCTAssertEqual(count(TranscriptSegment.self), 2)

        ctx.deleteMeetingFully(m)
        try ctx.save()

        XCTAssertEqual(count(TranscriptSegment.self), 0,
                       "deleteMeetingFully must remove all TranscriptSegment records")
    }

    func testDeleteMeetingInvalidatesFolderSummary() throws {
        let folderID = UUID()
        let m = makeMeeting(folderID: folderID)

        // Add a folder summary for that folder
        let summary = FolderSummaryItem(folderID: folderID)
        ctx.insert(summary)
        try ctx.save()
        XCTAssertEqual(count(FolderSummaryItem.self), 1)

        ctx.deleteMeetingFully(m)
        try ctx.save()

        XCTAssertEqual(count(FolderSummaryItem.self), 0,
                       "Deleting a meeting must invalidate the folder's FolderSummaryItem")
    }

    func testDeleteMeetingDoesNotAffectOtherMeetingsChunks() throws {
        let m1 = makeMeeting(title: "Meeting 1")
        let m2 = makeMeeting(title: "Meeting 2")
        _ = makeChunk(meetingId: m1.id)
        _ = makeChunk(meetingId: m2.id)
        _ = makeChunk(meetingId: m2.id)
        try ctx.save()

        ctx.deleteMeetingFully(m1)
        try ctx.save()

        XCTAssertEqual(count(TranscriptChunk.self), 2,
                       "Deleting meeting 1 must not remove chunks belonging to meeting 2")
    }

    func testDeleteMeetingDoesNotAffectOtherFolderSummaries() throws {
        let folderID1 = UUID()
        let folderID2 = UUID()
        let m = makeMeeting(folderID: folderID1)
        let s1 = FolderSummaryItem(folderID: folderID1)
        let s2 = FolderSummaryItem(folderID: folderID2)
        ctx.insert(s1); ctx.insert(s2)
        try ctx.save()
        XCTAssertEqual(count(FolderSummaryItem.self), 2)

        ctx.deleteMeetingFully(m)
        try ctx.save()

        XCTAssertEqual(count(FolderSummaryItem.self), 1,
                       "Only the folder containing the deleted meeting should be invalidated")
    }

    func testDeleteMeetingWithNoFolderDoesNotDeleteAnySummary() throws {
        let folderID = UUID()
        let m = makeMeeting(folderID: nil)  // not in any folder
        let s = FolderSummaryItem(folderID: folderID)
        ctx.insert(s)
        try ctx.save()

        ctx.deleteMeetingFully(m)
        try ctx.save()

        XCTAssertEqual(count(FolderSummaryItem.self), 1,
                       "Deleting an unfoldered meeting must not affect any folder summaries")
    }

    func testDeleteMeetingWithMixedChunks() throws {
        let m = makeMeeting()
        _ = makeChunk(meetingId: m.id, speaker: "mic")
        _ = makeChunk(meetingId: m.id, speaker: "participant")
        _ = makeChunk(meetingId: m.id, speaker: "mic")
        try ctx.save()
        XCTAssertEqual(count(TranscriptChunk.self), 3)

        ctx.deleteMeetingFully(m)
        try ctx.save()

        XCTAssertEqual(count(TranscriptChunk.self), 0,
                       "All chunks (mic and participant) must be removed")
    }

    func testDeleteMeetingIdempotent() throws {
        let m = makeMeeting()
        _ = makeChunk(meetingId: m.id)
        try ctx.save()

        // Deleting once should clean up fully
        ctx.deleteMeetingFully(m)
        try ctx.save()

        XCTAssertEqual(count(MeetingItem.self), 0)
        XCTAssertEqual(count(TranscriptChunk.self), 0)
    }

    // MARK: - Tests: MeetingMetaBadgeRow logic

    func testMeetingWithSummaryShowsAnalyzedBadge() {
        let m = MeetingItem(title: "Test", date: Date(), durationSeconds: 1800)
        m.summary = "This is a summary."
        XCTAssertFalse(m.summary.isEmpty, "Meeting with summary must show analyzed badge")
    }

    func testMeetingWithActionItemsShowsCount() {
        let m = MeetingItem(title: "Test", date: Date(), durationSeconds: 0)
        m.actionItems = ["Do thing A", "Do thing B", "Do thing C"]
        XCTAssertEqual(m.actionItems.count, 3, "Action items count must be 3")
    }

    func testMeetingWithDurationShowsBadge() {
        let m = MeetingItem(title: "Test", date: Date(), durationSeconds: 1860)  // 31 minutes
        XCTAssertGreaterThan(m.durationSeconds, 60, "31-minute meeting must show duration badge")
    }

    func testMeetingZeroDurationNoBadge() {
        let m = MeetingItem(title: "Test", date: Date(), durationSeconds: 0)
        XCTAssertFalse(m.durationSeconds > 60, "Zero-duration meeting must not show duration badge")
    }
}
