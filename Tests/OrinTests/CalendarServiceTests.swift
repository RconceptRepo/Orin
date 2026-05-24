import XCTest
@testable import Orin

/// Tests for CalendarService background sync timer management.
/// Actual EventKit sync is not tested here because it requires a real calendar
/// permission grant that the CI environment cannot provide.
@MainActor
final class CalendarServiceTests: XCTestCase {

    private var service: CalendarService!

    override func setUp() async throws {
        try await super.setUp()
        service = CalendarService()
    }

    override func tearDown() async throws {
        service.stopBackgroundSync()
        service = nil
        try await super.tearDown()
    }

    // MARK: - Background sync timer

    func testBackgroundSyncNotActiveByDefault() {
        XCTAssertFalse(service.isBackgroundSyncActive)
    }

    func testStartBackgroundSyncActivatesTimer() {
        service.startBackgroundSync()
        XCTAssertTrue(service.isBackgroundSyncActive)
    }

    func testStopBackgroundSyncDeactivatesTimer() {
        service.startBackgroundSync()
        service.stopBackgroundSync()
        XCTAssertFalse(service.isBackgroundSyncActive)
    }

    func testStartBackgroundSyncIsIdempotent() {
        service.startBackgroundSync()
        service.startBackgroundSync()   // second call must be a no-op
        service.startBackgroundSync()
        XCTAssertTrue(service.isBackgroundSyncActive, "Timer must be active after multiple start calls")
        // Stopping once must fully cancel it.
        service.stopBackgroundSync()
        XCTAssertFalse(service.isBackgroundSyncActive)
    }

    func testStopBackgroundSyncOnInactiveServiceDoesNotCrash() {
        // Calling stop when never started must be a no-op.
        service.stopBackgroundSync()
        service.stopBackgroundSync()
        XCTAssertFalse(service.isBackgroundSyncActive)
    }

    func testRestartBackgroundSync() {
        service.startBackgroundSync()
        service.stopBackgroundSync()
        service.startBackgroundSync()   // restart must work
        XCTAssertTrue(service.isBackgroundSyncActive)
    }

    // MARK: - Sync interval

    func testBackgroundSyncInterval() {
        XCTAssertEqual(CalendarService.backgroundSyncInterval, 900, "Background sync interval must be 15 minutes (900 s)")
    }

    // MARK: - Initial state

    func testInitialStatusIsRed() {
        XCTAssertEqual(service.status.title, "Unavailable")
    }

    func testInitialEventsAreEmpty() {
        XCTAssertTrue(service.events.isEmpty)
    }

    func testInitialLastSyncTimestampIsNil() {
        XCTAssertNil(service.lastSyncTimestamp)
    }

    // MARK: - Authorization status

    func testRefreshAuthorizationStatusDoesNotCrash() {
        // We can't grant permission in tests, but the method must not crash.
        service.refreshAuthorizationStatus()
        // Status will be .red (permission not granted in test environment) or .yellow
        // — just assert it's a valid state, not that it's a specific value.
        let validTitles = ["Synced", "Pending", "Unavailable"]
        XCTAssertTrue(validTitles.contains(service.status.title))
    }
}
