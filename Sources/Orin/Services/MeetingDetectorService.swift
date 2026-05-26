import AppKit
import EventKit
import Foundation
import Observation

@Observable
final class MeetingDetectorService: Service {

    // MARK: - Public State

    var detectedMeetingApp: String?
    var shouldShowRecordingPrompt = false
    /// Fired on the main thread the first time a new meeting session is discovered.
    var onMeetingDetected: ((String) -> Void)?

    // MARK: - Private Configuration

    private let nativeApps: [(bundleID: String, displayName: String)] = [
        ("us.zoom.xos",               "Zoom"),
        ("com.microsoft.teams",       "Microsoft Teams"),
        ("com.microsoft.teams2",      "Microsoft Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.cisco.webex.meetings",  "Webex"),
    ]

    private let chromiumBrowsers: [(bundleID: String, appName: String)] = [
        ("com.google.Chrome",          "Google Chrome"),
        ("com.microsoft.edgemac",      "Microsoft Edge"),
        ("company.thebrowser.Browser", "Arc"),
    ]

    let meetingURLPatterns: [String] = [
        // Google Meet
        "meet.google.com/",
        // Zoom — direct join, session, and web-client variants
        "zoom.us/j/",
        "zoom.us/s/",
        "zoom.us/wc/",
        // Microsoft Teams — consumer, new web, modern direct, and classic join-link
        "teams.live.com",
        "teams.microsoft.com/v2/",
        "teams.microsoft.com/meet/",
        "teams.microsoft.com/l/meetup-join",
        // Webex — browser-hosted meetings
        "web.webex.com/",
        "webex.com/meet/",
    ]

    // MARK: - Private State

    private var timer: Timer?

    /// Key of the currently detected meeting session.
    private var activeMeetingKey: String?

    /// Key of the most recently dismissed meeting session.
    /// Prevents re-prompting for the same ongoing meeting after the user explicitly dismissed.
    /// Cleared only when that meeting fully ends (detection returns nil).
    private var dismissedMeetingKey: String?

    /// Serial queue keeps NSAppleScript calls off the main thread and serialises concurrent access.
    private let scriptQueue = DispatchQueue(label: "com.orin.meeting-detector.applescript", qos: .utility)

    // MARK: - Dependencies

    /// Provides EventKit event data for the calendar-based detection path.
    /// Injected at init so tests can supply a fresh `CalendarService` without
    /// requiring EventKit authorization.
    private let calendarService: CalendarService

    // MARK: - Testing support

    /// Overrides the EventKit query performed by `detectFromCalendar()`.
    ///
    /// **For testing only.**  Set this closure before calling `startMonitoring()` to
    /// inject synthetic `EKEvent` objects without requiring real calendar authorization.
    /// The closure receives the same `(startDate, endDate)` arguments that would
    /// normally be passed to `CalendarService.events(from:to:)`.
    ///
    /// `nil` (the default) causes `detectFromCalendar()` to use the injected
    /// `CalendarService` directly.
    @ObservationIgnored
    var _calendarEventProviderOverride: ((Date, Date) -> [EKEvent])?

    // MARK: - Lifecycle

    /// Creates a `MeetingDetectorService`.
    ///
    /// - Parameter calendarService: The `CalendarService` used for EventKit queries in the
    ///   calendar-based detection path.  Defaults to a fresh instance, which is acceptable
    ///   in tests (the default `CalendarService` starts with `status == .red` and returns
    ///   empty event arrays, so calendar detection is a no-op until `_calendarEventProviderOverride`
    ///   is set or real calendar authorization is granted).
    init(calendarService: CalendarService = .init()) {
        self.calendarService = calendarService
    }

    @MainActor
    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; poll() dispatches work to a Task.
            self?.poll()
        }
        poll()
    }

    @MainActor
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        detectedMeetingApp = nil
        shouldShowRecordingPrompt = false
        activeMeetingKey = nil
        dismissedMeetingKey = nil
    }

    @MainActor
    func dismissPrompt() {
        shouldShowRecordingPrompt = false
        // Remember which session the user dismissed so we don't re-prompt
        // while the same meeting is still running. activeMeetingKey stays set
        // so the dedup guard in applyDetectionResult continues to suppress it.
        dismissedMeetingKey = activeMeetingKey
    }

    // MARK: - Polling (timer fires on main thread)

    private func poll() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let detection = await self.detectMeeting()
            await self.applyDetectionResult(detection)
        }
    }

    // MARK: - Detection pipeline (background-safe)

    private func detectMeeting() async -> (app: String, key: String)? {
        // Priority order: native app > calendar event > browser tab.
        //
        // Native apps are the most reliable signal (the meeting software is running).
        // Calendar events are proactive (a scheduled meeting is about to start or just started).
        // Browser tabs catch meetings joined without a native client.
        if let native   = detectNativeApp()    { return native   }
        if let calendar = detectFromCalendar() { return calendar }
        return await detectBrowserMeeting()
    }

    private func detectNativeApp() -> (app: String, key: String)? {
        let running = NSWorkspace.shared.runningApplications
        for config in nativeApps {
            guard let match = running.first(where: { $0.bundleIdentifier == config.bundleID }) else { continue }
            // Slack: only surface when a Huddle or call window is actually on-screen.
            if config.bundleID == "com.tinyspeck.slackmacgap", !slackHasActiveCall() { continue }
            return (app: match.localizedName ?? config.displayName, key: "\(config.bundleID)|active")
        }
        return nil
    }

    /// Best-effort check using CGWindowList; silently returns false if Screen Recording permission is absent.
    private func slackHasActiveCall() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return list.contains { info in
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info[kCGWindowName as String] as? String ?? ""
            guard owner.localizedCaseInsensitiveContains("Slack") else { return false }
            return title.localizedCaseInsensitiveContains("huddle")
                || title.localizedCaseInsensitiveContains("call")
                || title.localizedCaseInsensitiveContains("meeting")
        }
    }

    // MARK: - Calendar detection

    /// Scans EventKit events that overlap the [−2 min, +5 min] window around now
    /// for a known video-conference URL and returns the first match.
    ///
    /// The wide window ensures:
    ///   - Events that started up to 2 minutes ago are still detected (handles late joins).
    ///   - Events starting in the next 5 minutes trigger an early prompt.
    ///
    /// Called on a cooperative-thread-pool thread (inside `Task.detached` in `poll()`).
    /// Also safe to call directly from the main actor in tests.
    ///
    /// Returns `nil` when:
    ///   - Calendar access has not been granted (`status == .red`)
    ///   - No events exist in the window
    ///   - No events contain a recognised meeting URL
    func detectFromCalendar() -> (app: String, key: String)? {
        let now         = Date()
        let windowStart = now.addingTimeInterval(-(2 * 60))   // 2 minutes before now
        let windowEnd   = now.addingTimeInterval(  5 * 60)    // 5 minutes ahead

        let events: [EKEvent]
        if let provider = _calendarEventProviderOverride {
            events = provider(windowStart, windowEnd)
        } else {
            events = calendarService.events(from: windowStart, to: windowEnd)
        }

        for event in events {
            guard let info = extractMeetingInfo(from: event) else { continue }

            // Build a session key unique to this calendar occurrence.
            //
            // For saved recurring events, `EKEvent.eventIdentifier` is distinct for
            // each recurrence instance — a Monday standup and Tuesday standup will never
            // share a key, so dismissing one never suppresses the other.
            //
            // For unsaved test events, `eventIdentifier` is an empty string; fall back to
            // title + start-epoch so tests still get deterministic, stable keys.
            let rawID = event.eventIdentifier ?? ""
            let eventID: String
            if rawID.isEmpty {
                let epoch = Int(event.startDate.timeIntervalSince1970)
                eventID = "unsaved_\(event.title ?? "unknown")_\(epoch)"
            } else {
                eventID = rawID
            }

            let key     = "calendar|\(eventID)|\(info.stableURL)"
            let appName = event.title.map { "\(info.platform) — \($0)" } ?? info.platform
            return (app: appName, key: key)
        }
        return nil
    }

    /// Scans an `EKEvent`'s metadata fields for the first recognisable
    /// video-conference URL.
    ///
    /// Fields are checked in priority order:
    ///   1. `EKEvent.url`      — explicit URL set by a calendar client (e.g. Google Calendar)
    ///   2. `EKEvent.notes`    — free-text body; URL may be embedded in a sentence
    ///   3. `EKEvent.location` — some calendar apps paste join links here
    ///
    /// The returned `stableURL` has query-string and fragment stripped (via `stableKey`)
    /// so repeated polls for the same meeting produce an identical deduplication key.
    ///
    /// `internal` access so the test target can exercise it directly without constructing
    /// a full detection pipeline.
    func extractMeetingInfo(from event: EKEvent) -> (platform: String, stableURL: String)? {
        let candidates: [String] = [
            event.url?.absoluteString,
            event.notes,
            event.location
        ].compactMap { $0 }

        for text in candidates {
            for pattern in meetingURLPatterns {
                guard text.contains(pattern) else { continue }
                return (
                    platform:  platformName(for: pattern),
                    stableURL: stableKey(url: text, pattern: pattern)
                )
            }
        }
        return nil
    }

    /// Maps a URL pattern to its human-readable platform name.
    private func platformName(for pattern: String) -> String {
        if pattern.contains("google") { return "Google Meet"       }
        if pattern.contains("zoom")   { return "Zoom"              }
        if pattern.contains("teams")  { return "Microsoft Teams"   }
        if pattern.contains("webex")  { return "Webex"             }
        return "Meeting"
    }

    // MARK: - Browser detection

    private func detectBrowserMeeting() async -> (app: String, key: String)? {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        for browser in chromiumBrowsers {
            guard runningIDs.contains(browser.bundleID) else { continue }
            if let urls = await executeScript(chromiumTabScript(appName: browser.appName)),
               let meetingURL = firstMeetingURL(in: urls) {
                return (app: "\(browser.appName) – Meeting", key: "browser|\(meetingURL)")
            }
        }

        if runningIDs.contains("com.apple.Safari") {
            if let urls = await executeScript(safariTabScript()),
               let meetingURL = firstMeetingURL(in: urls) {
                return (app: "Safari – Meeting", key: "browser|\(meetingURL)")
            }
        }

        return nil
    }

    // MARK: - AppleScript execution

    /// Dispatches NSAppleScript to the serial scriptQueue via a continuation so the caller
    /// suspends rather than blocking a cooperative thread. Errors are swallowed silently.
    private func executeScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                var error: NSDictionary?
                let appleScript = NSAppleScript(source: source)
                let result = appleScript?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil ? result?.stringValue : nil)
            }
        }
    }

    private func chromiumTabScript(appName: String) -> String {
        """
        tell application "\(appName)"
            set urlList to ""
            repeat with w in windows
                try
                    set urlList to urlList & (URL of active tab of w) & "\n"
                on error
                end try
            end repeat
            return urlList
        end tell
        """
    }

    private func safariTabScript() -> String {
        """
        tell application "Safari"
            set urlList to ""
            repeat with w in windows
                try
                    set urlList to urlList & (URL of current tab of w) & "\n"
                on error
                end try
            end repeat
            return urlList
        end tell
        """
    }

    func firstMeetingURL(in urlString: String) -> String? {
        for url in urlString.components(separatedBy: "\n") {
            for pattern in meetingURLPatterns where url.contains(pattern) {
                return stableKey(url: url, pattern: pattern)
            }
        }
        return nil
    }

    /// Strips query-string and fragment so the same meeting URL deduplicates across polls.
    func stableKey(url: String, pattern: String) -> String {
        guard let range = url.range(of: pattern) else { return String(url.prefix(80)) }
        let path = String(url[range.lowerBound...])
            .components(separatedBy: CharacterSet(charactersIn: "?#"))
            .first ?? ""
        return String(path.prefix(80))
    }

    // MARK: - State update (main actor only)

    /// Internal so the test target can drive state transitions directly.
    @MainActor
    func applyDetectionResult(_ result: (app: String, key: String)?) {
        guard let result else {
            // Meeting ended — reset all session state so the next detection starts fresh.
            if detectedMeetingApp != nil || shouldShowRecordingPrompt {
                detectedMeetingApp = nil
                shouldShowRecordingPrompt = false
                activeMeetingKey = nil
                dismissedMeetingKey = nil
            }
            return
        }

        // Suppress if this is the same session that is already active OR was dismissed by the user.
        guard result.key != activeMeetingKey, result.key != dismissedMeetingKey else { return }

        activeMeetingKey = result.key
        detectedMeetingApp = result.app
        shouldShowRecordingPrompt = true
        onMeetingDetected?(result.app)
    }
}
