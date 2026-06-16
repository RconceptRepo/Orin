import XCTest
@testable import Orin

// MARK: - ActionItemFilterTests
//
// Pure unit tests for TranscriptChunker.isMeaningfulActionItem.
// No AI calls, no async, no fixtures — runs in < 1ms.

final class ActionItemFilterTests: XCTestCase {

    // MARK: - Acknowledgements: must be rejected

    func testRejectsYeah() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Yeah."))
    }

    func testRejectsRight() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Right."))
    }

    func testRejectsOkay() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Okay"))
    }

    func testRejectsOk() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Ok"))
    }

    func testRejectsSoundsGood() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Sounds good."))
    }

    func testRejectsGotIt() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Got it!"))
    }

    func testRejectsMmHmm() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Mm-hmm"))
    }

    func testRejectsUhHuh() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Uh huh"))
    }

    func testRejectsSure() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Sure"))
    }

    func testRejectsYes() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Yes"))
    }

    func testRejectsNoted() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Noted."))
    }

    func testRejectsUnderstood() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Understood"))
    }

    func testRejectsWillDo() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Will do"))
    }

    // MARK: - Minimum word count: must be rejected

    func testRejectsSingleWord() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Review"))
    }

    func testRejectsTwoWords() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Review proposal"))
    }

    func testRejectsEmptyString() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: ""))
    }

    func testRejectsPunctuationOnly() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "..."))
    }

    // MARK: - Real action items: must be accepted

    func testAcceptsThreeWordTask() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "Send the proposal"))
    }

    func testAcceptsMotorCatchTask() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "Check motor catch tasks"))
    }

    func testAcceptsFollowUpTask() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "Follow up with Anish about bandwidth changes"))
    }

    func testAcceptsScheduleTask() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "Schedule review meeting for Friday"))
    }

    func testAcceptsTaskWithPunctuation() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "Finalise motor catch tasks before Resocia onboarding."))
    }

    func testAcceptsCapitalisedTask() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "Send Updated Proposal To Client"))
    }

    func testAcceptsLongTask() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(
            task: "Coordinate with Kalyani and Anish to finalise the motor catch tasks before the Resocia Island client onboarding"))
    }

    // MARK: - Case and whitespace normalisation

    func testRejectsUppercaseYeah() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "YEAH"))
    }

    func testRejectsMixedCaseOkay() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Okay."))
    }

    func testRejectsTrailingWhitespace() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "  right  "))
    }

    func testAcceptsLeadingWhitespaceTask() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "  Send the report  "))
    }

    // MARK: - Edge cases

    func testRejectsShortNonAcknowledgement() {
        // Two meaningful words that aren't in the acknowledgements set — still rejected by word count
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Fix bug"))
    }

    func testAcceptsThreeShortWords() {
        // "Fix the bug" has 3 words of ≥2 chars each
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "Fix the bug"))
    }

    func testRejectsNumbersAlone() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "1 2 3"))
    }

    func testAcceptsTaskWithNumbers() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "Prepare Q3 report by Friday"))
    }

    // MARK: - Deduplication integration (TranscriptChunker.deduplicateActionItems)

    func testDeduplicateRemovesExactDuplicate() {
        let a = ActionItemRecord(owner: "Me", task: "Send the proposal to client")
        let b = ActionItemRecord(owner: "Me", task: "Send the proposal to client")
        let result = TranscriptChunker.deduplicateActionItems([a, b])
        XCTAssertEqual(result.count, 1)
    }

    func testDeduplicateKeepsDistinctItems() {
        let a = ActionItemRecord(owner: "Me", task: "Send the proposal to client")
        let b = ActionItemRecord(owner: "Me", task: "Schedule review meeting for Friday")
        let result = TranscriptChunker.deduplicateActionItems([a, b])
        XCTAssertEqual(result.count, 2)
    }

    func testDeduplicateKeepsMoreDetailedItem() {
        let noDate = ActionItemRecord(owner: "Me", task: "Send the proposal to client",
                                      priority: "High", dueDateText: "")
        let withDate = ActionItemRecord(owner: "Me", task: "Send the proposal to client",
                                        priority: "High", dueDateText: "Friday")
        let result = TranscriptChunker.deduplicateActionItems([noDate, withDate])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].dueDateText, "Friday")
    }

    func testDeduplicateHandlesTeamOwner() {
        let teamItem = ActionItemRecord(owner: "Team", task: "Review the bandwidth requirements")
        let meItem   = ActionItemRecord(owner: "Me", task: "Review the bandwidth requirements")
        let result = TranscriptChunker.deduplicateActionItems([teamItem, meItem])
        // Both match (Team is a wildcard owner in isDuplicateAction) — keep the more specific one
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Filter + dedup pipeline

    func testFilterThenDeduplicatePipeline() {
        let backchannel = ActionItemRecord(owner: "Me", task: "Yeah.")
        let real        = ActionItemRecord(owner: "Me", task: "Check motor catch tasks before onboarding")
        let duplicate   = ActionItemRecord(owner: "Me", task: "Check motor catch tasks before onboarding")

        let filtered = [backchannel, real, duplicate]
            .filter { TranscriptChunker.isMeaningfulActionItem(task: $0.task) }
        let deduped  = TranscriptChunker.deduplicateActionItems(filtered)

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].task, "Check motor catch tasks before onboarding")
    }
}
