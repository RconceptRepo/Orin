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

    func testRejectsThreeWordTask() {
        // 3 words no longer meets the 4-word minimum
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Send the proposal"))
    }

    func testAcceptsFourWordTask() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "Send the final proposal"))
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
        // Whitespace trimming works — 4-word task with leading/trailing spaces
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(task: "  Send the final report  "))
    }

    // MARK: - Edge cases

    func testRejectsShortNonAcknowledgement() {
        // Two meaningful words that aren't in the acknowledgements set — still rejected by word count
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Fix bug"))
    }

    func testRejectsThreeWords() {
        // 3 words is below the 4-word minimum, regardless of verb presence
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Fix the bug"))
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

    // MARK: - New acknowledgements (expanded set)

    func testRejectsMakesSense() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "Makes sense."))
    }

    func testRejectsThatMakesSense() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "That makes sense."))
    }

    // MARK: - Noun phrase without action verb: must be rejected

    func testRejectsTotalCostingFragment() {
        // Product Meeting false positive: 4 words but no action verb
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "the total costing and everything"))
    }

    func testRejectsNounPhraseWithoutVerb() {
        // "the project timeline status" has 4 words but none are action verbs
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "the project timeline status"))
    }

    func testRejectsFourWordsArticleOpenNoVerb() {
        XCTAssertFalse(TranscriptChunker.isMeaningfulActionItem(task: "the project scope discussion"))
    }

    // MARK: - Product Meeting action items: must be accepted

    func testAcceptsShareContactAction() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(
            task: "Share Bishek's contact details with ETH"))
    }

    func testAcceptsSetUpMeetingAction() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(
            task: "Set up coaching centre meetings this weekend"))
    }

    func testAcceptsWriteProposalAction() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(
            task: "Write medical use case proposal within two days"))
    }

    func testAcceptsCallHandoverAction() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(
            task: "Call Praveen to discuss content handover"))
    }

    func testAcceptsAttendEventAction() {
        XCTAssertTrue(TranscriptChunker.isMeaningfulActionItem(
            task: "Attend November event for networking and connections"))
    }

    // MARK: - Summary prompt: anti-verbatim instructions present

    func test_comprehensivePrompt_containsAntiVerbatimInstruction() {
        let service = MeetingIntelligenceService(aiService: AIService(config: AIConfiguration(primaryProvider: .ollama)))
        let prompt = service.buildComprehensivePrompt(
            title: "Product Meeting",
            transcript: "Me: Okay. Makes sense.",
            meetingType: "general"
        )
        XCTAssertTrue(prompt.contains("Do NOT copy"),
            "Prompt must instruct model not to copy transcript lines verbatim")
        XCTAssertTrue(prompt.contains("speaker label"),
            "Prompt must forbid beginning with a speaker label")
        XCTAssertTrue(prompt.contains("Insufficient information for summary"),
            "Prompt must specify fallback text when no meaningful discussion exists")
    }

    func test_synthesisPrompt_containsAntiVerbatimInstruction() {
        let prompt = TranscriptChunker.buildSynthesisPrompt(
            keyPointsText: "• Discussed budget constraints",
            decisionsCount: 1,
            actionsCount: 2,
            title: "Team Meeting"
        )
        XCTAssertTrue(prompt.contains("Do NOT copy"),
            "Synthesis prompt must instruct model not to copy key-point text verbatim")
        XCTAssertTrue(prompt.contains("speaker label"),
            "Synthesis prompt must forbid starting with a speaker label")
        XCTAssertTrue(prompt.contains("Insufficient information for summary"),
            "Synthesis prompt must specify fallback text for empty topic list")
    }

    // MARK: - Keyword fallback threshold constant

    func test_keywordFallbackThreshold_is3000() {
        // Product Meeting was 9,986 chars — well above this threshold.
        // Confirms long meetings will not receive keyword-fallback action items.
        XCTAssertEqual(MeetingIntelligenceService.keywordFallbackTranscriptThreshold, 3_000)
    }
}
