import XCTest
@testable import Orin

/// Tests for Automation (AppleScript) permission diagnostics and recovery.
///
/// All tests use `_browserScriptExecutorOverride` and `_runningBrowserIDsOverride` to inject
/// synthetic outcomes without running real NSAppleScript.  This makes every scenario
/// reproducible on any machine regardless of which browsers are installed or whether the
/// test runner has Automation permission.
///
/// The class is `@MainActor` because `automationPermissionStatus` is updated via
/// `applyAutomationStatus` which is `@MainActor`, and `retryBrowserDetection` /
/// `stopMonitoring` are also `@MainActor`.
@MainActor
final class AutomationPermissionTests: XCTestCase {

    // MARK: - Permission Granted

    func testAutomationStatusGrantedWhenScriptSucceeds() async {
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome"]
        svc._browserScriptExecutorOverride = { _ in .urls("https://github.com\nhttps://notion.so\n") }

        _ = await svc.detectBrowserMeeting()

        XCTAssertEqual(svc.automationPermissionStatus, .granted,
                       "Status must be .granted when AppleScript executes without error")
    }

    func testMeetingURLReturnedWhenPermissionGranted() async {
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome"]
        svc._browserScriptExecutorOverride = { _ in .urls("https://meet.google.com/abc-def-ghi\n") }

        let result = await svc.detectBrowserMeeting()

        XCTAssertNotNil(result, "A meeting result must be returned when permission is granted and URL matches")
        XCTAssertTrue(result?.key.hasPrefix("browser|") == true)
        XCTAssertEqual(svc.automationPermissionStatus, .granted)
    }

    func testGrantedStatusPrioritisedOverPartialDenial() async {
        // Chrome grants → status must be .granted even if Safari denies.
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome", "com.apple.Safari"]
        svc._browserScriptExecutorOverride = { source in
            // Chrome's AppleScript source contains "Google Chrome"; Safari's contains "Safari".
            if source.contains("Google Chrome") { return .urls("https://github.com\n") }
            return .permissionDenied
        }

        _ = await svc.detectBrowserMeeting()

        XCTAssertEqual(svc.automationPermissionStatus, .granted,
                       "Granted status must take priority when at least one browser responds")
    }

    // MARK: - Permission Denied

    func testAutomationStatusDeniedWhenScriptReturnsPermissionDenied() async {
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome"]
        svc._browserScriptExecutorOverride = { _ in .permissionDenied }

        _ = await svc.detectBrowserMeeting()

        XCTAssertEqual(svc.automationPermissionStatus, .denied,
                       "Status must be .denied when NSAppleScript returns -1743")
    }

    func testPermissionDeniedReturnsNilResult() async {
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome"]
        svc._browserScriptExecutorOverride = { _ in .permissionDenied }

        let result = await svc.detectBrowserMeeting()

        XCTAssertNil(result, "Permission-denied script must not produce a meeting detection result")
    }

    func testPermissionDeniedStatusPersistsAcrossPolls() async {
        // Three consecutive polls while denied — status stays .denied without oscillating.
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome"]
        svc._browserScriptExecutorOverride = { _ in .permissionDenied }

        _ = await svc.detectBrowserMeeting()
        _ = await svc.detectBrowserMeeting()
        _ = await svc.detectBrowserMeeting()

        XCTAssertEqual(svc.automationPermissionStatus, .denied)
    }

    // MARK: - Permission Revoked

    func testPermissionRevokedTransitionsToDenied() async {
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome"]

        // Poll 1: Automation is granted.
        svc._browserScriptExecutorOverride = { _ in .urls("https://github.com\n") }
        _ = await svc.detectBrowserMeeting()
        XCTAssertEqual(svc.automationPermissionStatus, .granted)

        // Poll 2: Automation is revoked in System Settings while app is running.
        svc._browserScriptExecutorOverride = { _ in .permissionDenied }
        _ = await svc.detectBrowserMeeting()

        XCTAssertEqual(svc.automationPermissionStatus, .denied,
                       "Status must transition to .denied when permission is revoked mid-session")
    }

    func testRetryResetsStatusToUnknown() async {
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome"]
        svc._browserScriptExecutorOverride = { _ in .permissionDenied }

        _ = await svc.detectBrowserMeeting()
        XCTAssertEqual(svc.automationPermissionStatus, .denied)

        // User opens System Settings, grants access, then taps "Retry" in the toast.
        // retryBrowserDetection() must reset status to .unknown before the next poll fires.
        svc.retryBrowserDetection()

        XCTAssertEqual(svc.automationPermissionStatus, .unknown,
                       "retryBrowserDetection() must reset status so the next poll starts fresh")
    }

    func testGrantedAfterRetryUpdatesStatusCorrectly() async {
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome"]

        // Initial denial.
        svc._browserScriptExecutorOverride = { _ in .permissionDenied }
        _ = await svc.detectBrowserMeeting()
        XCTAssertEqual(svc.automationPermissionStatus, .denied)

        // User grants access and taps Retry.
        svc.retryBrowserDetection()

        // Next poll succeeds.
        svc._browserScriptExecutorOverride = { _ in .urls("") }
        _ = await svc.detectBrowserMeeting()

        XCTAssertEqual(svc.automationPermissionStatus, .granted,
                       "Status must return to .granted after user grants Automation access")
    }

    // MARK: - Browser Unavailable

    func testAutomationStatusUnavailableWhenNoBrowserRunning() async {
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = []  // no supported browser is running

        _ = await svc.detectBrowserMeeting()

        XCTAssertEqual(svc.automationPermissionStatus, .unavailable,
                       "Status must be .unavailable when no supported browser is running")
    }

    func testBrowserUnavailableReturnsNilAndSkipsScript() async {
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = []
        svc._browserScriptExecutorOverride = { _ in
            XCTFail("Script executor must not be called when no browser is running")
            return .urls("")
        }

        let result = await svc.detectBrowserMeeting()
        XCTAssertNil(result, "No result must be returned when no browser is running")
    }

    // MARK: - Silent failure prevention

    func testScriptErrorLeavesStatusUnchanged() async {
        // A raw AppleScript error (not -1743, not -600) must not flip status to .granted or .denied.
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome"]
        svc._browserScriptExecutorOverride = { _ in .scriptError(-1708) }  // errAENotFound

        _ = await svc.detectBrowserMeeting()

        XCTAssertEqual(svc.automationPermissionStatus, .unknown,
                       "Script errors must leave automationPermissionStatus unchanged")
    }

    func testStopMonitoringResetsAutomationStatus() async {
        let svc = MeetingDetectorService()
        svc._runningBrowserIDsOverride = ["com.google.Chrome"]

        // Bring status to .granted so we have something non-trivial to reset.
        svc._browserScriptExecutorOverride = { _ in .urls("") }
        _ = await svc.detectBrowserMeeting()
        XCTAssertEqual(svc.automationPermissionStatus, .granted)

        svc.stopMonitoring()

        XCTAssertEqual(svc.automationPermissionStatus, .unknown,
                       "stopMonitoring() must reset automationPermissionStatus to .unknown")
    }
}
