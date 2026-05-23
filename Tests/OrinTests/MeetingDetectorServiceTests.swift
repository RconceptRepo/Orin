import XCTest
@testable import Orin

@MainActor
final class MeetingDetectorServiceTests: XCTestCase {

    // MARK: - Deduplication

    func testSameMeetingDoesNotRetriggerPrompt() async {
        let service = MeetingDetectorService()
        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))

        XCTAssertTrue(service.shouldShowRecordingPrompt)
        XCTAssertEqual(service.detectedMeetingApp, "Zoom")

        // Simulate the next 30-second poll finding the same session still running.
        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))

        // Prompt must stay true but the callback must not have fired again.
        XCTAssertTrue(service.shouldShowRecordingPrompt)
    }

    func testCallbackFiresOnlyForNewSession() async {
        let service = MeetingDetectorService()
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))

        XCTAssertEqual(callbackCount, 1, "Callback must fire exactly once per unique session")
    }

    func testDifferentMeetingKeyFiresNewCallback() async {
        let service = MeetingDetectorService()
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        await service.applyDetectionResult(nil)   // meeting ends, state reset
        await service.applyDetectionResult((app: "Google Chrome", key: "browser|meet.google.com/abc"))

        XCTAssertEqual(callbackCount, 2)
    }

    // MARK: - Dismiss behaviour

    func testDismissHidesPromptWithoutClearingSession() async {
        let service = MeetingDetectorService()
        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        XCTAssertTrue(service.shouldShowRecordingPrompt)

        service.dismissPrompt()
        XCTAssertFalse(service.shouldShowRecordingPrompt)
        // The meeting name is still tracked so the engine knows the session is live.
        XCTAssertEqual(service.detectedMeetingApp, "Zoom")
    }

    func testDismissedSessionDoesNotRepromptWhileStillRunning() async {
        let service = MeetingDetectorService()
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.dismissPrompt()

        // Same meeting still detected on subsequent polls.
        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))

        XCTAssertFalse(service.shouldShowRecordingPrompt, "Must not re-prompt for dismissed session")
        XCTAssertEqual(callbackCount, 1, "Callback must not fire again for dismissed session")
    }

    func testNewMeetingAfterDismissDoesPrompt() async {
        let service = MeetingDetectorService()
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.dismissPrompt()

        // A new, different meeting starts while the old one is still running.
        await service.applyDetectionResult((app: "Google Chrome", key: "browser|meet.google.com/xyz"))

        XCTAssertTrue(service.shouldShowRecordingPrompt, "A new meeting must trigger the prompt")
        XCTAssertEqual(callbackCount, 2)
    }

    // MARK: - Meeting-end state reset

    func testMeetingEndResetsOverlay() async {
        let service = MeetingDetectorService()
        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        XCTAssertTrue(service.shouldShowRecordingPrompt)
        XCTAssertNotNil(service.detectedMeetingApp)

        // Meeting disappears (no active detection).
        await service.applyDetectionResult(nil)

        XCTAssertFalse(service.shouldShowRecordingPrompt, "Overlay must clear when meeting ends")
        XCTAssertNil(service.detectedMeetingApp)
    }

    func testMeetingEndAfterDismissResetsAllState() async {
        let service = MeetingDetectorService()
        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.dismissPrompt()
        await service.applyDetectionResult(nil)   // meeting ends

        // Now the same meeting can start fresh and re-prompt.
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        XCTAssertTrue(service.shouldShowRecordingPrompt)
        XCTAssertEqual(callbackCount, 1, "Session must be re-detectable after the previous instance ended")
    }

    func testNoOpWhenAlreadyCleared() async {
        let service = MeetingDetectorService()
        // Calling nil detection on a clean service must not crash or corrupt state.
        await service.applyDetectionResult(nil)
        await service.applyDetectionResult(nil)
        XCTAssertFalse(service.shouldShowRecordingPrompt)
        XCTAssertNil(service.detectedMeetingApp)
    }

    // MARK: - Stop monitoring

    func testStopMonitoringClearsState() async {
        let service = MeetingDetectorService()
        await service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.stopMonitoring()
        XCTAssertFalse(service.shouldShowRecordingPrompt)
        XCTAssertNil(service.detectedMeetingApp)
    }

    // MARK: - URL helpers

    func testStableKeyStripsQueryString() {
        let service = MeetingDetectorService()
        let url = "https://meet.google.com/abc-defg-hij?authuser=0&hl=en"
        let key = service.stableKey(url: url, pattern: "meet.google.com/")
        XCTAssertEqual(key, "meet.google.com/abc-defg-hij")
    }

    func testStableKeyStripsFragment() {
        let service = MeetingDetectorService()
        let url = "https://zoom.us/j/123456789#success"
        let key = service.stableKey(url: url, pattern: "zoom.us/j/")
        XCTAssertEqual(key, "zoom.us/j/123456789")
    }

    func testFirstMeetingURLMatchesKnownPatterns() {
        let service = MeetingDetectorService()
        let urlBlock = """
        https://www.google.com
        https://meet.google.com/aaa-bbbb-ccc
        https://github.com
        """
        let result = service.firstMeetingURL(in: urlBlock)
        XCTAssertEqual(result, "meet.google.com/aaa-bbbb-ccc")
    }

    func testFirstMeetingURLReturnsNilForNoMatch() {
        let service = MeetingDetectorService()
        let result = service.firstMeetingURL(in: "https://github.com\nhttps://notion.so")
        XCTAssertNil(result)
    }

    func testFirstMeetingURLMatchesZoomSession() {
        let service = MeetingDetectorService()
        let result = service.firstMeetingURL(in: "https://zoom.us/j/98765432100?pwd=abc")
        XCTAssertEqual(result, "zoom.us/j/98765432100")
    }

    func testFirstMeetingURLMatchesTeams() {
        let service = MeetingDetectorService()
        let result = service.firstMeetingURL(in: "https://teams.microsoft.com/v2/#/calling/join")
        XCTAssertEqual(result, "teams.microsoft.com/v2/")
    }
}
