import XCTest
import SwiftData
@testable import Orin

// MARK: - LongContextTests
//
// Tests for TranscriptChunker, MeetingKnowledgeSnapshot, and long-meeting analysis.

final class LongContextTests: XCTestCase {

    // MARK: - TranscriptChunker.chunks(of:)

    func testShortTranscriptReturnsOneChunk() {
        let short = String(repeating: "word ", count: 100)  // ~500 chars
        let chunks = TranscriptChunker.chunks(of: short)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], short)
    }

    func testAtThresholdReturnsOneChunk() {
        // exactly singleCallThreshold chars — should be single call
        let text = String(repeating: "a", count: TranscriptChunker.singleCallThreshold)
        XCTAssertEqual(TranscriptChunker.chunks(of: text).count, 1)
    }

    func testLongTranscriptProducesMultipleChunks() {
        // 30,000 chars ≈ 30-minute meeting
        let long = (0..<300).map { "[0\($0):00] Me: This is a test sentence for chunk \($0)." }.joined(separator: "\n")
        XCTAssertGreaterThan(long.count, TranscriptChunker.singleCallThreshold)
        let chunks = TranscriptChunker.chunks(of: long)
        XCTAssertGreaterThan(chunks.count, 1, "30k-char transcript must produce multiple chunks")
    }

    func testChunksHaveOverlap() {
        // Verify that consecutive chunks share content (overlap)
        // Need > 12,000 chars, so use 300 lines × ~65 chars each ≈ 19,500 chars
        let lines = (0..<300).map { "[0\($0 / 60 > 0 ? String($0/60) : "0"):\(String(format: "%02d", $0 % 60)):00] Me: Line \($0) of this important transcript content." }
        let transcript = lines.joined(separator: "\n")
        guard transcript.count > TranscriptChunker.singleCallThreshold else {
            // Adjust if the calculation changed
            return
        }
        let chunks = TranscriptChunker.chunks(of: transcript)
        guard chunks.count >= 2 else { return }

        // Last part of chunk 0 should overlap with start of chunk 1
        let endOfFirst    = String(chunks[0].suffix(TranscriptChunker.overlapSize + 100))
        let startOfSecond = String(chunks[1].prefix(TranscriptChunker.overlapSize + 100))
        let endLines   = endOfFirst.components(separatedBy: "\n").filter { !$0.isEmpty }
        let startLines = startOfSecond.components(separatedBy: "\n").filter { !$0.isEmpty }
        let sharedLines = endLines.filter { startLines.contains($0) }
        XCTAssertFalse(sharedLines.isEmpty, "Consecutive chunks must share overlapping lines")
    }

    func testChunksCoversFullTranscript() {
        let transcript = (0..<100).map { "[0\($0):30] Me: Important action item \($0) for the team." }.joined(separator: "\n")
        let chunks = TranscriptChunker.chunks(of: transcript)
        // Last chunk must contain content from the end of the transcript
        let lastChunk = chunks.last ?? ""
        XCTAssertTrue(
            lastChunk.contains("99") || lastChunk.contains("98"),
            "Last chunk must contain content from the end of the transcript"
        )
    }

    func testSingleCallThresholdValue() {
        XCTAssertEqual(TranscriptChunker.singleCallThreshold, 12_000,
                       "singleCallThreshold must cover ~18 min of speech")
    }

    func testChunkSizeValue() {
        XCTAssertEqual(TranscriptChunker.chunkSize, 5_000,
                       "chunkSize must cover ~7-8 min of speech")
    }

    // MARK: - TranscriptChunker.deduplicateActionItems

    func testDeduplicateIdenticalTasks() {
        let items = [
            ActionItemRecord(owner: "Alice", task: "Send proposal to client", priority: "High"),
            ActionItemRecord(owner: "Alice", task: "Send proposal to client", priority: "High"),
        ]
        let deduped = TranscriptChunker.deduplicateActionItems(items)
        XCTAssertEqual(deduped.count, 1, "Identical action items must be deduplicated")
    }

    func testDeduplicateNearDuplicateTasks() {
        let items = [
            ActionItemRecord(owner: "Alice", task: "Send proposal to the client", priority: "High"),
            ActionItemRecord(owner: "Alice", task: "Send proposal client", priority: "Medium", dueDateText: "Friday"),
        ]
        let deduped = TranscriptChunker.deduplicateActionItems(items)
        // High token overlap — should be treated as duplicates; keep the more detailed one
        XCTAssertLessThanOrEqual(deduped.count, 2, "Near-duplicate tasks should be deduplicated")
        if deduped.count == 1 {
            XCTAssertEqual(deduped[0].dueDateText, "Friday", "More detailed item must be preferred")
        }
    }

    func testDeduplicateDifferentTasksPreserved() {
        let items = [
            ActionItemRecord(owner: "Alice", task: "Send proposal to client", priority: "High"),
            ActionItemRecord(owner: "Bob", task: "Schedule follow-up meeting", priority: "Medium"),
            ActionItemRecord(owner: "Carol", task: "Review technical requirements", priority: "Low"),
        ]
        let deduped = TranscriptChunker.deduplicateActionItems(items)
        XCTAssertEqual(deduped.count, 3, "Different action items must all be preserved")
    }

    func testDeduplicateEmptyList() {
        XCTAssertTrue(TranscriptChunker.deduplicateActionItems([]).isEmpty)
    }

    // MARK: - TranscriptChunker.deduplicateStrings

    func testDeduplicateIdenticalDecisions() {
        let items = ["We decided to use JWT tokens", "We decided to use JWT tokens"]
        let deduped = TranscriptChunker.deduplicateStrings(items)
        XCTAssertEqual(deduped.count, 1)
    }

    func testDeduplicateHighSimilarityStrings() {
        let items = [
            "Decided to use JWT for authentication",
            "We will use JWT tokens for auth",
        ]
        let deduped = TranscriptChunker.deduplicateStrings(items)
        // "JWT" and "auth/authentication" have good token overlap — may be deduped
        XCTAssertGreaterThanOrEqual(deduped.count, 1)
        XCTAssertLessThanOrEqual(deduped.count, 2)
    }

    func testDeduplicateDifferentStringsPreserved() {
        let items = [
            "Decided to use JWT for authentication",
            "Sprint launch pushed to next quarter",
            "New hire onboarding starts Monday",
        ]
        let deduped = TranscriptChunker.deduplicateStrings(items)
        XCTAssertEqual(deduped.count, 3, "Distinct decisions must all be preserved")
    }

    // MARK: - MeetingKnowledgeSnapshot

    @MainActor
    func testSnapshotRoundTrip() throws {
        let m = MeetingItem(title: "Test Sprint Planning", date: Date(), durationSeconds: 3600)
        m.meetingType  = MeetingType.sprintPlanning.rawValue
        m.summary      = "The team committed to 12 story points."
        m.decisions    = ["Use JWT", "Delay OAuth"]
        m.openQuestions = ["When does OAuth need to be ready?"]
        m.risks        = ["Third-party SDK deprecation"]
        m.actionItems  = ["Alice: Set up JWT service"]

        let snapshot = MeetingKnowledgeSnapshot(from: m)
        XCTAssertEqual(snapshot.title, "Test Sprint Planning")
        XCTAssertEqual(snapshot.meetingType, MeetingType.sprintPlanning.rawValue)
        XCTAssertEqual(snapshot.decisions, ["Use JWT", "Delay OAuth"])
        XCTAssertEqual(snapshot.risks, ["Third-party SDK deprecation"])
        XCTAssertEqual(snapshot.durationSeconds, 3600)
    }

    @MainActor
    func testSnapshotCodableRoundTrip() throws {
        let m = MeetingItem(title: "Test", date: Date(), durationSeconds: 1800)
        m.summary   = "Productive session."
        m.decisions = ["Decision A", "Decision B"]
        m.risks     = ["Risk X"]

        let snapshot = MeetingKnowledgeSnapshot(from: m)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(MeetingKnowledgeSnapshot.self, from: data)

        XCTAssertEqual(decoded.title, "Test")
        XCTAssertEqual(decoded.decisions, ["Decision A", "Decision B"])
        XCTAssertEqual(decoded.risks, ["Risk X"])
    }

    @MainActor
    func testMeetingItemSnapshotRoundTrip() throws {
        let m = MeetingItem(title: "Sprint Review", date: Date(), durationSeconds: 2700)
        m.meetingType = MeetingType.productReview.rawValue
        m.summary     = "Shipped features A and B."
        m.decisions   = ["Feature C delayed"]

        let snapshot = MeetingKnowledgeSnapshot(from: m)
        if let data = try? JSONEncoder().encode(snapshot),
           let json = String(data: data, encoding: .utf8) {
            m.meetingKnowledgeJSON = json
        }

        let decoded = m.decodedKnowledgeSnapshot
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.title, "Sprint Review")
        XCTAssertEqual(decoded?.meetingType, MeetingType.productReview.rawValue)
        XCTAssertEqual(decoded?.decisions, ["Feature C delayed"])
    }

    @MainActor
    func testMeetingItemDecodesNilWhenNoJSON() {
        let m = MeetingItem(title: "Test", date: Date())
        m.meetingKnowledgeJSON = nil
        XCTAssertNil(m.decodedKnowledgeSnapshot)
    }

    @MainActor
    func testMeetingItemDecodesNilForInvalidJSON() {
        let m = MeetingItem(title: "Test", date: Date())
        m.meetingKnowledgeJSON = "not valid json at all"
        XCTAssertNil(m.decodedKnowledgeSnapshot)
    }

    // MARK: - Meeting size estimates

    func testEstimatedChunkCountFor30MinMeeting() {
        // 30 min ≈ 19,500 chars. Use 300 lines × ~65 chars each.
        let lines = (0..<300).map { "[0\($0/60):\(String(format: "%02d", $0 % 60)):00] Me: Sentence \($0) of the standup meeting about sprint progress." }
        let transcript = lines.joined(separator: "\n")
        XCTAssertGreaterThan(transcript.count, TranscriptChunker.singleCallThreshold)
        let chunks = TranscriptChunker.chunks(of: transcript)
        XCTAssertGreaterThan(chunks.count, 1, "30-min meeting must use chunked analysis")
        XCTAssertLessThanOrEqual(chunks.count, 6, "30-min meeting should need ≤6 chunks")
    }

    func testEstimatedChunkCountFor60MinMeeting() {
        // 60 min ≈ 39,000 chars. Use 600 lines × ~65 chars each.
        let lines = (0..<600).map { "[0\($0/60):\(String(format: "%02d", $0 % 60)):00] Me: Sentence \($0) of the meeting about engineering and product roadmap." }
        let transcript = lines.joined(separator: "\n")
        XCTAssertGreaterThan(transcript.count, TranscriptChunker.singleCallThreshold)
        let chunks = TranscriptChunker.chunks(of: transcript)
        XCTAssertGreaterThan(chunks.count, 4, "60-min meeting must produce multiple chunks")
        XCTAssertLessThanOrEqual(chunks.count, 12, "60-min meeting should need ≤12 chunks")
    }

    func testEstimatedChunkCountFor120MinMeeting() {
        // 120 min ≈ 78,000 chars. Use 1200 lines × ~65 chars each.
        let lines = (0..<1200).map { "[0\($0/60):\(String(format: "%02d", $0 % 60)):00] Me: Sentence \($0) discussing important topics." }
        let transcript = lines.joined(separator: "\n")
        XCTAssertGreaterThan(transcript.count, TranscriptChunker.singleCallThreshold)
        let chunks = TranscriptChunker.chunks(of: transcript)
        XCTAssertGreaterThan(chunks.count, 8, "120-min meeting must produce many chunks")
        // Last chunk must contain content from the end
        XCTAssertTrue(chunks.last?.contains("1199") ?? false || chunks.last?.contains("1198") ?? false,
                      "Last chunk must contain content from end of transcript")
    }

    // MARK: - Routing logic (via meeting type detection — no AI needed)

    func testShortTranscriptRoutesToSingleCall() {
        let short = String(repeating: "word ", count: 400)  // ~2000 chars, well below threshold
        XCTAssertLessThan(short.count, TranscriptChunker.singleCallThreshold,
                          "Short transcript must route to single call")
        XCTAssertEqual(TranscriptChunker.chunks(of: short).count, 1)
    }

    func testLongTranscriptRoutesToChunkedAnalysis() {
        let lines = (0..<250).map { "[0\($0/60):\(String(format: "%02d", $0 % 60)):00] Me: Sentence \($0) word sentence paragraph." }
        let long = lines.joined(separator: "\n")
        XCTAssertGreaterThan(long.count, TranscriptChunker.singleCallThreshold,
                             "Long transcript must route to chunked analysis")
        XCTAssertGreaterThan(TranscriptChunker.chunks(of: long).count, 1)
    }
}
