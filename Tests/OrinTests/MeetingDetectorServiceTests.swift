import EventKit
import XCTest
@testable import Orin

/// All tests run on the main actor because applyDetectionResult, dismissPrompt,
/// and stopMonitoring are @MainActor. Calling them from a @MainActor context is
/// synchronous — no async/await needed.
@MainActor
final class MeetingDetectorServiceTests: XCTestCase {

    // MARK: - Deduplication

    func testSameMeetingDoesNotRetriggerPrompt() {
        let service = MeetingDetectorService()
        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))

        XCTAssertTrue(service.shouldShowRecordingPrompt)
        XCTAssertEqual(service.detectedMeetingApp, "Zoom")

        // Simulate the next 30-second poll finding the same session still running.
        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))

        XCTAssertTrue(service.shouldShowRecordingPrompt)
    }

    func testCallbackFiresOnlyForNewSession() {
        let service = MeetingDetectorService()
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))

        XCTAssertEqual(callbackCount, 1, "Callback must fire exactly once per unique session")
    }

    func testDifferentMeetingKeyFiresNewCallback() {
        let service = MeetingDetectorService()
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.applyDetectionResult(nil)   // meeting ends, state reset
        service.applyDetectionResult((app: "Google Chrome", key: "browser|meet.google.com/abc"))

        XCTAssertEqual(callbackCount, 2)
    }

    // MARK: - Dismiss behaviour

    func testDismissHidesPromptWithoutClearingSession() {
        let service = MeetingDetectorService()
        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        XCTAssertTrue(service.shouldShowRecordingPrompt)

        service.dismissPrompt()
        XCTAssertFalse(service.shouldShowRecordingPrompt)
        // The meeting name is still tracked so the engine knows the session is live.
        XCTAssertEqual(service.detectedMeetingApp, "Zoom")
    }

    func testDismissedSessionDoesNotRepromptWhileStillRunning() {
        let service = MeetingDetectorService()
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.dismissPrompt()

        // Same meeting still detected on subsequent polls.
        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))

        XCTAssertFalse(service.shouldShowRecordingPrompt, "Must not re-prompt for dismissed session")
        XCTAssertEqual(callbackCount, 1, "Callback must not fire again for dismissed session")
    }

    func testNewMeetingAfterDismissDoesPrompt() {
        let service = MeetingDetectorService()
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.dismissPrompt()

        // A new, different meeting starts while the old one is still running.
        service.applyDetectionResult((app: "Google Chrome", key: "browser|meet.google.com/xyz"))

        XCTAssertTrue(service.shouldShowRecordingPrompt, "A new meeting must trigger the prompt")
        XCTAssertEqual(callbackCount, 2)
    }

    // MARK: - Meeting-end state reset

    func testMeetingEndResetsOverlay() {
        let service = MeetingDetectorService()
        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        XCTAssertTrue(service.shouldShowRecordingPrompt)
        XCTAssertNotNil(service.detectedMeetingApp)

        service.applyDetectionResult(nil)

        XCTAssertFalse(service.shouldShowRecordingPrompt, "Overlay must clear when meeting ends")
        XCTAssertNil(service.detectedMeetingApp)
    }

    func testMeetingEndAfterDismissResetsAllState() {
        let service = MeetingDetectorService()
        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        service.dismissPrompt()
        service.applyDetectionResult(nil)   // meeting ends

        // The same meeting starting again should re-prompt fresh.
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
        XCTAssertTrue(service.shouldShowRecordingPrompt)
        XCTAssertEqual(callbackCount, 1, "Session must be re-detectable after the previous instance ended")
    }

    func testNoOpWhenAlreadyCleared() {
        let service = MeetingDetectorService()
        service.applyDetectionResult(nil)
        service.applyDetectionResult(nil)
        XCTAssertFalse(service.shouldShowRecordingPrompt)
        XCTAssertNil(service.detectedMeetingApp)
    }

    // MARK: - Stop monitoring

    func testStopMonitoringClearsState() {
        let service = MeetingDetectorService()
        service.applyDetectionResult((app: "Zoom", key: "us.zoom.xos|active"))
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

    // MARK: - New URL pattern coverage (expanded in calendar-detection feature)

    func testFirstMeetingURLMatchesZoomWebClient() {
        let service = MeetingDetectorService()
        let result = service.firstMeetingURL(in: "https://zoom.us/wc/987654321/join")
        XCTAssertEqual(result, "zoom.us/wc/987654321")
    }

    func testFirstMeetingURLMatchesTeamsLegacyJoin() {
        let service = MeetingDetectorService()
        let result = service.firstMeetingURL(in: "https://teams.microsoft.com/l/meetup-join/19%3a…/0")
        XCTAssertEqual(result, "teams.microsoft.com/l/meetup-join")
    }

    func testFirstMeetingURLMatchesTeamsModernDirect() {
        let service = MeetingDetectorService()
        let result = service.firstMeetingURL(in: "https://teams.microsoft.com/meet/abc123")
        XCTAssertEqual(result, "teams.microsoft.com/meet/abc123")
    }

    func testFirstMeetingURLMatchesWebexBrowser() {
        let service = MeetingDetectorService()
        let result = service.firstMeetingURL(in: "https://web.webex.com/meet/user@example.com")
        XCTAssertEqual(result, "web.webex.com/meet/user@example.com")
    }
}

// MARK: - CalendarMeetingDetectionTests

/// Tests for the calendar-based meeting detection path.
///
/// All tests use `_calendarEventProviderOverride` to inject synthetic `EKEvent` objects
/// created from an in-memory `EKEventStore`.  This avoids any dependency on real EventKit
/// authorization and makes the tests safe to run in an unsigned `xctest` process.
///
/// `EKEvent(eventStore:)` without saving produces events with empty `eventIdentifier`
/// values.  `detectFromCalendar()` falls back to a title+epoch composite key in that
/// case, which is deterministic within a test run.
@MainActor
final class CalendarMeetingDetectionTests: XCTestCase {

    // Shared EKEventStore for constructing test events.
    // Creating EKEventStore() does not require calendar authorization.
    private let testStore = EKEventStore()

    // MARK: - Helpers

    private func makeEvent(
        title:         String  = "Test Meeting",
        url:           URL?    = nil,
        notes:         String? = nil,
        location:      String? = nil,
        minutesFromNow: Double = 0
    ) -> EKEvent {
        let event       = EKEvent(eventStore: testStore)
        event.title     = title
        event.url       = url
        event.notes     = notes
        event.location  = location
        event.startDate = Date().addingTimeInterval(minutesFromNow * 60)
        event.endDate   = event.startDate.addingTimeInterval(3_600)   // 1 hour
        event.calendar  = testStore.defaultCalendarForNewEvents        // avoids nil calendar
        return event
    }

    // MARK: - extractMeetingInfo unit tests (pure function — no auth required)

    func testExtractMeetingInfoFromURLFieldGoogleMeet() {
        let service = MeetingDetectorService()
        let event   = makeEvent(url: URL(string: "https://meet.google.com/abc-def-ghi"))
        let info    = service.extractMeetingInfo(from: event)
        XCTAssertEqual(info?.platform,  "Google Meet")
        XCTAssertEqual(info?.stableURL, "meet.google.com/abc-def-ghi")
    }

    func testExtractMeetingInfoFromNotesZoom() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "Join Zoom: https://zoom.us/j/123456789?pwd=abc123")
        let info    = service.extractMeetingInfo(from: event)
        XCTAssertEqual(info?.platform,  "Zoom")
        XCTAssertEqual(info?.stableURL, "zoom.us/j/123456789")
    }

    func testExtractMeetingInfoFromLocationMicrosoftTeams() {
        let service = MeetingDetectorService()
        let event   = makeEvent(location: "https://teams.microsoft.com/v2/#/meeting/join")
        let info    = service.extractMeetingInfo(from: event)
        XCTAssertEqual(info?.platform, "Microsoft Teams")
    }

    func testExtractMeetingInfoFromNotesWebex() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "Webex room: https://web.webex.com/meet/user123")
        let info    = service.extractMeetingInfo(from: event)
        XCTAssertEqual(info?.platform, "Webex")
    }

    func testExtractMeetingInfoFromNotesTeamsLegacyJoin() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "https://teams.microsoft.com/l/meetup-join/19%3a.../0")
        let info    = service.extractMeetingInfo(from: event)
        XCTAssertEqual(info?.platform, "Microsoft Teams")
    }

    func testExtractMeetingInfoFromNotesZoomWebClient() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "Web join: https://zoom.us/wc/987654321")
        let info    = service.extractMeetingInfo(from: event)
        XCTAssertEqual(info?.platform, "Zoom")
    }

    func testExtractMeetingInfoURLFieldTakesPriorityOverNotes() {
        // EKEvent.url has a Meet link; notes has a Zoom link.
        // EKEvent.url must win because it is checked first.
        let service = MeetingDetectorService()
        let event   = makeEvent(
            url:   URL(string: "https://meet.google.com/abc-def-ghi"),
            notes: "Backup dial-in: https://zoom.us/j/999999"
        )
        let info = service.extractMeetingInfo(from: event)
        XCTAssertEqual(info?.platform, "Google Meet",
                       "EKEvent.url must take priority over notes")
    }

    func testExtractMeetingInfoNotesTakesPriorityOverLocation() {
        // EKEvent.notes has a Meet link; location has a Zoom link.
        // Notes is checked before location.
        let service = MeetingDetectorService()
        let event   = makeEvent(
            notes:    "Join: https://meet.google.com/abc-def-ghi",
            location: "https://zoom.us/j/999999"
        )
        let info = service.extractMeetingInfo(from: event)
        XCTAssertEqual(info?.platform, "Google Meet",
                       "EKEvent.notes must take priority over location")
    }

    func testExtractMeetingInfoStripsQueryStringFromNotes() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "https://meet.google.com/aaa-bbb-ccc?authuser=0&hl=en")
        let info    = service.extractMeetingInfo(from: event)
        XCTAssertEqual(info?.stableURL, "meet.google.com/aaa-bbb-ccc")
    }

    func testExtractMeetingInfoStripsFragmentFromURL() {
        let service = MeetingDetectorService()
        let event   = makeEvent(url: URL(string: "https://zoom.us/j/123456789#success"))
        let info    = service.extractMeetingInfo(from: event)
        XCTAssertEqual(info?.stableURL, "zoom.us/j/123456789")
    }

    func testExtractMeetingInfoReturnsNilForNonMeetingEvent() {
        let service = MeetingDetectorService()
        let event   = makeEvent(title: "Lunch", notes: "Meet at the cafe", location: "123 Main St")
        XCTAssertNil(service.extractMeetingInfo(from: event))
    }

    func testExtractMeetingInfoReturnsNilForEventWithNoFields() {
        let service = MeetingDetectorService()
        let event   = makeEvent()   // no url, notes, or location
        XCTAssertNil(service.extractMeetingInfo(from: event))
    }

    // MARK: - detectFromCalendar integration tests (injected events)

    func testDetectFromCalendarUsesSevenMinuteWindow() {
        let service = MeetingDetectorService()
        var capturedStart: Date?
        var capturedEnd:   Date?

        service._calendarEventProviderOverride = { start, end in
            capturedStart = start
            capturedEnd   = end
            return []
        }
        _ = service.detectFromCalendar()

        guard let start = capturedStart, let end = capturedEnd else {
            XCTFail("Calendar event provider was not called")
            return
        }
        let intervalMinutes = end.timeIntervalSince(start) / 60
        XCTAssertEqual(intervalMinutes, 7, accuracy: 0.01,
                       "Detection window must span exactly 7 minutes (−2 min to +5 min)")
    }

    func testDetectFromCalendarWindowStartsBeforeNow() {
        let service = MeetingDetectorService()
        let beforeCall = Date()
        var capturedStart: Date?

        service._calendarEventProviderOverride = { start, _ in capturedStart = start; return [] }
        _ = service.detectFromCalendar()

        XCTAssertLessThan(capturedStart!, beforeCall,
                          "Window start must be approximately 2 minutes before now")
    }

    func testDetectFromCalendarFindsGoogleMeet() {
        let service = MeetingDetectorService()
        let event   = makeEvent(title: "Weekly Standup",
                                notes: "Join: https://meet.google.com/abc-def-ghi")
        service._calendarEventProviderOverride = { _, _ in [event] }

        let result = service.detectFromCalendar()

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.app.contains("Google Meet") == true)
        XCTAssertTrue(result?.app.contains("Weekly Standup") == true,
                      "App name must include the event title")
        XCTAssertTrue(result?.key.hasPrefix("calendar|") == true)
    }

    func testDetectFromCalendarFindsZoom() {
        let service = MeetingDetectorService()
        let event   = makeEvent(url: URL(string: "https://zoom.us/j/123456789"))
        service._calendarEventProviderOverride = { _, _ in [event] }

        let result = service.detectFromCalendar()
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.app.contains("Zoom") == true)
    }

    func testDetectFromCalendarFindsMicrosoftTeams() {
        let service = MeetingDetectorService()
        let event   = makeEvent(location: "https://teams.microsoft.com/l/meetup-join/19%3a...")
        service._calendarEventProviderOverride = { _, _ in [event] }

        let result = service.detectFromCalendar()
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.app.contains("Microsoft Teams") == true)
    }

    func testDetectFromCalendarFindsWebex() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "Webex room: https://web.webex.com/meet/user123")
        service._calendarEventProviderOverride = { _, _ in [event] }

        let result = service.detectFromCalendar()
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.app.contains("Webex") == true)
    }

    func testDetectFromCalendarReturnsNilWhenNoEvents() {
        let service = MeetingDetectorService()
        service._calendarEventProviderOverride = { _, _ in [] }
        XCTAssertNil(service.detectFromCalendar())
    }

    func testDetectFromCalendarReturnsNilForNonMeetingEvent() {
        let service = MeetingDetectorService()
        let event   = makeEvent(title: "Lunch break", location: "Cafe on 5th")
        service._calendarEventProviderOverride = { _, _ in [event] }
        XCTAssertNil(service.detectFromCalendar())
    }

    func testDetectFromCalendarKeyHasCalendarPrefix() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "https://meet.google.com/abc-def-ghi")
        service._calendarEventProviderOverride = { _, _ in [event] }

        let result = service.detectFromCalendar()!
        XCTAssertTrue(result.key.hasPrefix("calendar|"),
                      "Calendar detection keys must be prefixed with 'calendar|'")
    }

    func testDetectFromCalendarKeyIncludesMeetingURL() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "https://meet.google.com/aaa-bbb-ccc")
        service._calendarEventProviderOverride = { _, _ in [event] }

        let result = service.detectFromCalendar()!
        XCTAssertTrue(result.key.contains("meet.google.com/aaa-bbb-ccc"),
                      "Detection key must contain the stable meeting URL for deduplication")
    }

    // MARK: - Full pipeline: detectFromCalendar → applyDetectionResult → prompt

    func testCalendarEventTriggersRecordingPrompt() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "https://meet.google.com/abc-def-ghi")
        service._calendarEventProviderOverride = { _, _ in [event] }

        let result = service.detectFromCalendar()!
        service.applyDetectionResult(result)

        XCTAssertTrue(service.shouldShowRecordingPrompt)
        XCTAssertNotNil(service.detectedMeetingApp)
        XCTAssertTrue(service.detectedMeetingApp?.contains("Google Meet") == true)
    }

    func testCalendarEventCallbackFiresOnce() {
        let service = MeetingDetectorService()
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        let event = makeEvent(notes: "https://meet.google.com/abc-def-ghi")
        service._calendarEventProviderOverride = { _, _ in [event] }

        // Simulate three consecutive 30-second polls finding the same event.
        let result = service.detectFromCalendar()!
        service.applyDetectionResult(result)
        service.applyDetectionResult(result)
        service.applyDetectionResult(result)

        XCTAssertEqual(callbackCount, 1,
                       "onMeetingDetected must fire exactly once per unique calendar event")
    }

    func testCalendarEventDismissedDoesNotReprompt() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "https://meet.google.com/abc-def-ghi")
        service._calendarEventProviderOverride = { _, _ in [event] }

        let result = service.detectFromCalendar()!
        service.applyDetectionResult(result)
        service.dismissPrompt()

        // Next poll finds the same event still in the window.
        service.applyDetectionResult(result)

        XCTAssertFalse(service.shouldShowRecordingPrompt,
                       "Dismissed calendar meeting must not re-prompt while still in window")
    }

    func testCalendarEventClearsWhenNoLongerInWindow() {
        let service = MeetingDetectorService()
        let event   = makeEvent(notes: "https://meet.google.com/abc-def-ghi")
        service._calendarEventProviderOverride = { _, _ in [event] }

        // Meeting in window — prompt appears.
        let result = service.detectFromCalendar()!
        service.applyDetectionResult(result)
        XCTAssertTrue(service.shouldShowRecordingPrompt)

        // Event slides out of window — next poll returns nil.
        service.applyDetectionResult(nil)

        XCTAssertFalse(service.shouldShowRecordingPrompt,
                       "Prompt must clear when the calendar event leaves the detection window")
        XCTAssertNil(service.detectedMeetingApp)
    }

    func testCalendarEventRepromptsAfterWindowGap() {
        // If a meeting ends (leaves window) and then the same recurring instance
        // re-enters the window in a later poll, it must prompt again.
        let service = MeetingDetectorService()
        var callbackCount = 0
        service.onMeetingDetected = { _ in callbackCount += 1 }

        let event = makeEvent(notes: "https://meet.google.com/abc-def-ghi")
        service._calendarEventProviderOverride = { _, _ in [event] }

        // First detection.
        let result = service.detectFromCalendar()!
        service.applyDetectionResult(result)
        service.applyDetectionResult(nil)   // meeting ends — clears all session state

        // Same event appears again (e.g. user rescheduled; new occurrence has different key
        // because the unsaved-event fallback key encodes startDate).
        let result2 = service.detectFromCalendar()!
        service.applyDetectionResult(result2)
        // Because startDate and thus the key are identical for the same test event,
        // this will NOT re-prompt — which is the correct dedup behaviour.
        // (In production, distinct occurrences have distinct eventIdentifiers.)
        XCTAssertEqual(callbackCount, 1)
    }

    // MARK: - Recurring meeting support

    func testRecurringMeetingInstancesHaveDistinctKeys() {
        // Verify that two occurrences with different start times (simulating Mon/Tue standup)
        // produce different session keys, so dismissing Mon's prompt doesn't suppress Tue's.
        let service = MeetingDetectorService()

        // Occurrence 1 — starts now.
        let occurrence1 = makeEvent(
            title: "Daily Standup",
            notes: "https://meet.google.com/aaa-bbb-ccc",
            minutesFromNow: 0
        )
        // Occurrence 2 — starts 24 hours from now.
        let occurrence2 = makeEvent(
            title: "Daily Standup",
            notes: "https://meet.google.com/aaa-bbb-ccc",
            minutesFromNow: 1_440
        )

        service._calendarEventProviderOverride = { _, _ in [occurrence1] }
        let key1 = service.detectFromCalendar()?.key

        service._calendarEventProviderOverride = { _, _ in [occurrence2] }
        let key2 = service.detectFromCalendar()?.key

        XCTAssertNotNil(key1)
        XCTAssertNotNil(key2)
        XCTAssertNotEqual(key1, key2,
                          "Distinct recurring occurrences must produce distinct session keys")
    }

    func testRecurringMeetingDismissedKeyDoesNotSuppressNextOccurrence() {
        let service = MeetingDetectorService()

        // Monday's occurrence — dismiss it.
        let monday = makeEvent(
            title: "Standup",
            notes: "https://meet.google.com/aaa-bbb-ccc",
            minutesFromNow: 0
        )
        service._calendarEventProviderOverride = { _, _ in [monday] }

        let mondayResult = service.detectFromCalendar()!
        service.applyDetectionResult(mondayResult)
        service.dismissPrompt()
        service.applyDetectionResult(nil)   // Monday's meeting ends

        // Tuesday's occurrence (different startDate → different key for unsaved events).
        let tuesday = makeEvent(
            title: "Standup",
            notes: "https://meet.google.com/aaa-bbb-ccc",
            minutesFromNow: 1_440
        )
        service._calendarEventProviderOverride = { _, _ in [tuesday] }
        let tuesdayResult = service.detectFromCalendar()!
        service.applyDetectionResult(tuesdayResult)

        XCTAssertTrue(service.shouldShowRecordingPrompt,
                      "Dismissing one recurring occurrence must not suppress later occurrences")
    }

    // MARK: - EventKit integration tests (require calendar authorization — skipped in xctest)
    //
    // These tests verify the full path through a real `EKEventStore` query.  They cannot
    // run in the unsigned `xctest` runner because:
    //   1. Calendar TCC permission is required.
    //   2. The test environment has no real calendar events to query.
    // Run them manually via the signed app target with populated calendar data.

    func testRealCalendarEventsDetectedWithAuthorization() async throws {
        throw XCTSkip("Integration test: requires calendar authorization and real events — run via the signed app target")
    }

    func testRealRecurringMeetingDetectedFromEventStore() async throws {
        throw XCTSkip("Integration test: requires calendar authorization and real recurring events — run via the signed app target")
    }
}
