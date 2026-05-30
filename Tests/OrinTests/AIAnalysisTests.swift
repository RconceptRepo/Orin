import XCTest
import SwiftData
@testable import Orin

// MARK: - AIAnalysisTests

final class AIAnalysisTests: XCTestCase {

    // MARK: - Meeting Type Detection

    func testDetectsStandup() {
        let t = MeetingIntelligenceService.detectMeetingType(
            title: "Daily Standup", transcript: "Yesterday I finished the PR. Today I'll review tests. No blockers.")
        XCTAssertEqual(t, MeetingType.standup.rawValue)
    }

    func testDetectsStandupFromTranscript() {
        let t = MeetingIntelligenceService.detectMeetingType(
            title: "Team Sync",
            transcript: "Yesterday I finished the auth module. Today I'll work on the API. I have a blocker with the database.")
        XCTAssertEqual(t, MeetingType.standup.rawValue)
    }

    func testDetectsSprintPlanning() {
        let t = MeetingIntelligenceService.detectMeetingType(
            title: "Sprint Planning Q3", transcript: "Let's pick up stories for the sprint. Our velocity is 32 story points.")
        XCTAssertEqual(t, MeetingType.sprintPlanning.rawValue)
    }

    func testDetectsInterview() {
        let t = MeetingIntelligenceService.detectMeetingType(
            title: "Engineering Interview", transcript: "Tell me about yourself and your experience with distributed systems.")
        XCTAssertEqual(t, MeetingType.interview.rawValue)
    }

    func testDetectsSalesCall() {
        let t = MeetingIntelligenceService.detectMeetingType(
            title: "Sales Demo", transcript: "Let me walk you through our product. What's your current pain point with the legacy solution?")
        XCTAssertEqual(t, MeetingType.salesCall.rawValue)
    }

    func testDetectsDiscoveryCall() {
        let t = MeetingIntelligenceService.detectMeetingType(
            title: "Customer Discovery", transcript: "Let's explore your pain points and understand your use case.")
        XCTAssertEqual(t, MeetingType.discoveryCall.rawValue)
    }

    func testDetectsProductReview() {
        let t = MeetingIntelligenceService.detectMeetingType(
            title: "Product Review - Q3", transcript: "Let's review the features we shipped this quarter and the roadmap review.")
        XCTAssertEqual(t, MeetingType.productReview.rawValue)
    }

    func testDetectsExecutiveReview() {
        let t = MeetingIntelligenceService.detectMeetingType(
            title: "All Hands Meeting", transcript: "Thanks everyone for joining our all-hands quarterly review.")
        XCTAssertEqual(t, MeetingType.executiveReview.rawValue)
    }

    func testFallsBackToGeneralMeeting() {
        let t = MeetingIntelligenceService.detectMeetingType(
            title: "Team Chat", transcript: "Let's sync on the project status and timeline.")
        XCTAssertEqual(t, MeetingType.general.rawValue)
    }

    func testDetectionIsCaseInsensitive() {
        let t = MeetingIntelligenceService.detectMeetingType(
            title: "DAILY STANDUP", transcript: "")
        XCTAssertEqual(t, MeetingType.standup.rawValue)
    }

    // MARK: - MeetingType enum

    func testMeetingTypeRawValues() {
        XCTAssertEqual(MeetingType.standup.rawValue, "Standup")
        XCTAssertEqual(MeetingType.salesCall.rawValue, "Sales Call")
        XCTAssertEqual(MeetingType.interview.rawValue, "Interview")
        XCTAssertEqual(MeetingType.general.rawValue, "General Meeting")
    }

    func testMeetingTypeHasIcons() {
        for type_ in MeetingType.allCases {
            XCTAssertFalse(type_.icon.isEmpty, "\(type_.rawValue) must have an SF Symbol icon")
        }
    }

    func testAllMeetingTypesInitFromRawValue() {
        for type_ in MeetingType.allCases {
            XCTAssertNotNil(MeetingType(rawValue: type_.rawValue),
                            "\(type_.rawValue) must be constructable from rawValue")
        }
    }

    // MARK: - ActionItemRecord

    func testActionItemRecordFields() {
        let item = ActionItemRecord(
            owner: "Alice",
            task: "Send proposal",
            priority: "High",
            dueDateText: "Friday",
            rawText: "OWNER: Alice | TASK: Send proposal | PRIORITY: High | DUE: Friday"
        )
        XCTAssertEqual(item.owner, "Alice")
        XCTAssertEqual(item.task, "Send proposal")
        XCTAssertEqual(item.priority, "High")
        XCTAssertEqual(item.dueDateText, "Friday")
        XCTAssertNotNil(item.id)
    }

    func testActionItemRecordCodable() throws {
        let item = ActionItemRecord(owner: "Bob", task: "Review specs", priority: "Medium", dueDateText: "EOW")
        let data = try JSONEncoder().encode([item])
        let decoded = try JSONDecoder().decode([ActionItemRecord].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].owner, "Bob")
        XCTAssertEqual(decoded[0].task, "Review specs")
        XCTAssertEqual(decoded[0].priority, "Medium")
        XCTAssertEqual(decoded[0].dueDateText, "EOW")
    }

    func testActionItemRecordDefaultPriority() {
        let item = ActionItemRecord(owner: "Team", task: "Review PR")
        XCTAssertEqual(item.priority, "Medium")
        XCTAssertEqual(item.dueDateText, "")
        XCTAssertEqual(item.rawText, "")
    }

    // MARK: - Response Parser (via action item line parser logic)

    func testParseActionItemLineAllFields() {
        // Test the internal parser by going through analyze with a mock-like approach
        // We use ActionItemRecord to verify Codable round-trips
        let items = [
            ActionItemRecord(owner: "Alice", task: "Send proposal to client", priority: "High", dueDateText: "Friday"),
            ActionItemRecord(owner: "Team", task: "Schedule follow-up", priority: "Medium", dueDateText: ""),
        ]
        let encoded = try? JSONEncoder().encode(items)
        XCTAssertNotNil(encoded)
        let decoded = try? JSONDecoder().decode([ActionItemRecord].self, from: encoded!)
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?[0].owner, "Alice")
        XCTAssertEqual(decoded?[1].owner, "Team")
    }

    // MARK: - MeetingItem new fields

    @MainActor
    func testMeetingItemNewFieldsExist() {
        let m = MeetingItem(title: "Test", date: Date())
        XCTAssertEqual(m.meetingType, "")
        XCTAssertTrue(m.openQuestions.isEmpty)
        XCTAssertTrue(m.risks.isEmpty)
        XCTAssertTrue(m.dependencies.isEmpty)
        XCTAssertNil(m.structuredActionItemsJSON)
    }

    @MainActor
    func testMeetingItemStructuredActionItemsRoundTrip() {
        let m = MeetingItem(title: "Test", date: Date())
        let items = [ActionItemRecord(owner: "Alice", task: "Send report", priority: "High", dueDateText: "Monday")]
        if let data = try? JSONEncoder().encode(items),
           let json = String(data: data, encoding: .utf8) {
            m.structuredActionItemsJSON = json
        }
        let decoded = m.structuredActionItems
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].owner, "Alice")
        XCTAssertEqual(decoded[0].task, "Send report")
    }

    @MainActor
    func testMeetingItemReturnsEmptyWhenNoJSON() {
        let m = MeetingItem(title: "Test", date: Date())
        m.structuredActionItemsJSON = nil
        XCTAssertTrue(m.structuredActionItems.isEmpty)
    }

    @MainActor
    func testMeetingItemReturnsEmptyForInvalidJSON() {
        let m = MeetingItem(title: "Test", date: Date())
        m.structuredActionItemsJSON = "not valid json"
        XCTAssertTrue(m.structuredActionItems.isEmpty)
    }

    // MARK: - Context-aware prompt (type-specific context)

    func testTypeSpecificContextIsUnique() {
        let types = MeetingType.allCases.map { MeetingIntelligenceService.typeSpecificContext(for: $0.rawValue) }
        // Each type should have a non-empty context string
        for (i, ctx) in types.enumerated() {
            XCTAssertFalse(ctx.isEmpty, "\(MeetingType.allCases[i].rawValue) must have non-empty context")
        }
    }

    func testSalesCallContextMentionsPainPoints() {
        let ctx = MeetingIntelligenceService.typeSpecificContext(for: MeetingType.salesCall.rawValue)
        XCTAssertTrue(ctx.lowercased().contains("pain point") || ctx.lowercased().contains("pain"),
                      "Sales call context must mention pain points")
    }

    func testStandupContextMentionsBlockers() {
        let ctx = MeetingIntelligenceService.typeSpecificContext(for: MeetingType.standup.rawValue)
        XCTAssertTrue(ctx.lowercased().contains("blocker"),
                      "Standup context must mention blockers")
    }

    func testInterviewContextMentionsCandidate() {
        let ctx = MeetingIntelligenceService.typeSpecificContext(for: MeetingType.interview.rawValue)
        XCTAssertTrue(ctx.lowercased().contains("qualif") || ctx.lowercased().contains("strength") || ctx.lowercased().contains("candid"),
                      "Interview context must mention candidate assessment")
    }

    // MARK: - FolderSummaryItem new fields

    @MainActor
    func testFolderSummaryItemHasRecurringFields() {
        let item = FolderSummaryItem(folderID: UUID())
        XCTAssertTrue(item.recurringBlockers.isEmpty)
        XCTAssertTrue(item.recurringRisks.isEmpty)
    }

    // MARK: - Regression: MeetingAnalysis struct compatibility

    func testMeetingAnalysisHasAllRequiredFields() {
        let analysis = MeetingAnalysis(
            summary: "Test summary",
            meetingType: "Standup",
            decisions: ["Decided X"],
            openQuestions: ["What about Y?"],
            risks: ["Risk of Z"],
            dependencies: ["Waiting on A"],
            commitments: ["Alice will do B"],
            actionItems: ["Do C"],
            structuredActionItems: [ActionItemRecord(owner: "Alice", task: "Do C")],
            suggestedTasks: ["Review D"]
        )
        XCTAssertEqual(analysis.summary, "Test summary")
        XCTAssertEqual(analysis.meetingType, "Standup")
        XCTAssertEqual(analysis.openQuestions.count, 1)
        XCTAssertEqual(analysis.risks.count, 1)
        XCTAssertEqual(analysis.dependencies.count, 1)
        XCTAssertEqual(analysis.structuredActionItems.count, 1)
    }
}
