import XCTest
@testable import Orin

/// Tests URL scheme / deep link parsing in AssistantService.
/// We verify the UserDefaults bridge keys that the app's processPendingIntents reads.
@MainActor
final class URLSchemeTests: XCTestCase {

    private var service: AssistantService!

    // Keys cleared before and after each test to keep isolation
    private let reflowKey  = "orin.pendingIntentReflow"
    private let summaryKey = "orin.pendingIntentSummary"
    private let taskKey    = "orin.pendingIntentTask"

    override func setUp() async throws {
        try await super.setUp()
        service = AssistantService()
        clearDefaults()
    }

    override func tearDown() async throws {
        clearDefaults()
        service = nil
        try await super.tearDown()
    }

    // MARK: - Handled URLs

    func testWhatsLeftTodayURLSetsFlag() {
        let url = URL(string: "orin://whatsLeftToday")!
        let handled = service.handleURL(url)
        XCTAssertTrue(handled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: summaryKey))
    }

    func testReflowURLSetsFlag() {
        let url = URL(string: "orin://reflow")!
        let handled = service.handleURL(url)
        XCTAssertTrue(handled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: reflowKey))
    }

    func testAddTaskURLWithTitle() {
        let url = URL(string: "orin://addTask?title=finish%20proposal")!
        let handled = service.handleURL(url)
        XCTAssertTrue(handled)
        XCTAssertEqual(UserDefaults.standard.string(forKey: taskKey), "finish proposal")
    }

    func testAddTaskURLWithTitleAndDue() {
        let url = URL(string: "orin://addTask?title=review%20PR&due=tomorrow")!
        let handled = service.handleURL(url)
        XCTAssertTrue(handled)
        let stored = UserDefaults.standard.string(forKey: taskKey) ?? ""
        XCTAssertTrue(stored.contains("review PR"))
        XCTAssertTrue(stored.contains("tomorrow"))
    }

    func testAddTaskURLWithEmptyTitleDoesNotSetKey() {
        let url = URL(string: "orin://addTask?title=")!
        let handled = service.handleURL(url)
        XCTAssertTrue(handled, "URL is still handled even with empty title")
        XCTAssertNil(UserDefaults.standard.string(forKey: taskKey))
    }

    // MARK: - Unhandled URLs

    func testWrongSchemeReturnsfalse() {
        let url = URL(string: "https://example.com")!
        XCTAssertFalse(service.handleURL(url))
    }

    func testUnknownHostReturnsFalse() {
        let url = URL(string: "orin://unknownCommand")!
        XCTAssertFalse(service.handleURL(url))
    }

    // MARK: - Helpers

    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: reflowKey)
        UserDefaults.standard.removeObject(forKey: summaryKey)
        UserDefaults.standard.removeObject(forKey: taskKey)
    }
}
