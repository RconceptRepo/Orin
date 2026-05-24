import XCTest
@testable import Orin

final class QuickCaptureParserTests: XCTestCase {

    // MARK: - Basic parsing

    func testTitleOnly() {
        let result = QuickCaptureParser.parse("Write project proposal")
        XCTAssertEqual(result?.title, "Write project proposal")
        XCTAssertEqual(result?.priority, .p3Low)
        XCTAssertNil(result?.dueDate)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(QuickCaptureParser.parse(""))
        XCTAssertNil(QuickCaptureParser.parse("   "))
    }

    // MARK: - Priority tokens

    func testP0Priority() {
        let result = QuickCaptureParser.parse("Fix production bug P0")
        XCTAssertEqual(result?.priority, .p0Critical)
        XCTAssertEqual(result?.title, "Fix production bug")
    }

    func testP1Priority() {
        let result = QuickCaptureParser.parse("Review PRs P1")
        XCTAssertEqual(result?.priority, .p1High)
        XCTAssertEqual(result?.title, "Review PRs")
    }

    func testP2Priority() {
        let result = QuickCaptureParser.parse("Update docs P2")
        XCTAssertEqual(result?.priority, .p2Medium)
    }

    func testP3Priority() {
        let result = QuickCaptureParser.parse("Clean up notes P3")
        XCTAssertEqual(result?.priority, .p3Low)
    }

    func testPriorityIsCaseInsensitive() {
        let lower = QuickCaptureParser.parse("Finish report p1")
        XCTAssertEqual(lower?.priority, .p1High)
        XCTAssertEqual(lower?.title, "Finish report")
    }

    func testDefaultPriorityIsP3() {
        let result = QuickCaptureParser.parse("A task with no priority token")
        XCTAssertEqual(result?.priority, .p3Low)
    }

    func testOnlyPriorityTokenReturnsNil() {
        XCTAssertNil(QuickCaptureParser.parse("P0"))
    }

    // MARK: - Due date tokens

    func testTodayDueDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let result = QuickCaptureParser.parse("Team standup today", calendar: calendar)
        let expected = calendar.startOfDay(for: Date())
        XCTAssertEqual(result?.dueDate, expected)
        XCTAssertEqual(result?.title, "Team standup")
    }

    func testTomorrowDueDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let result = QuickCaptureParser.parse("Send invoice tomorrow", calendar: calendar)
        let expected = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        XCTAssertEqual(result?.dueDate, expected)
        XCTAssertEqual(result?.title, "Send invoice")
    }

    func testTodayKeywordCaseInsensitive() {
        XCTAssertNotNil(QuickCaptureParser.parse("Task Today")?.dueDate)
        XCTAssertNotNil(QuickCaptureParser.parse("Task today")?.dueDate)
        XCTAssertNotNil(QuickCaptureParser.parse("Task TODAY")?.dueDate)
    }

    func testOnlyDateTokenReturnsNil() {
        XCTAssertNil(QuickCaptureParser.parse("today"))
        XCTAssertNil(QuickCaptureParser.parse("P1 today"))
    }

    // MARK: - Combined tokens

    func testPriorityAndDueDate() {
        let result = QuickCaptureParser.parse("Ship hotfix tomorrow P0")
        XCTAssertEqual(result?.priority, .p0Critical)
        XCTAssertNotNil(result?.dueDate)
        XCTAssertEqual(result?.title, "Ship hotfix")
    }

    func testTokensInAnyOrder() {
        let r1 = QuickCaptureParser.parse("Deploy update P1 today")
        let r2 = QuickCaptureParser.parse("Deploy update today P1")
        XCTAssertEqual(r1?.title, r2?.title)
        XCTAssertEqual(r1?.priority, r2?.priority)
        XCTAssertEqual(r1?.dueDate, r2?.dueDate)
    }

    func testTitlePreservesInternalSpacing() {
        let result = QuickCaptureParser.parse("Write a detailed spec doc P2")
        XCTAssertEqual(result?.title, "Write a detailed spec doc")
    }

    func testLeadingAndTrailingWhitespace() {
        let result = QuickCaptureParser.parse("  Tidy whitespace  ")
        XCTAssertEqual(result?.title, "Tidy whitespace")
    }
}
