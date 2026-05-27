import AppKit
import EventKit
import Foundation
import Observation
import OSLog

@Observable
final class MeetingDetectorService: Service {

    // MARK: - Nested Types

    /// Typed result of a single NSAppleScript execution.
    ///
    /// Having a typed outcome — rather than a bare `String?` — means every failure mode is
    /// handled explicitly and the browser detection path can never swallow errors silently.
    enum BrowserScriptOutcome {
        /// Script executed successfully. Value is the raw newline-separated URL list (may be empty).
        case urls(String)
        /// NSAppleScript error -1743 (`errAEEventNotPermitted`): Automation permission denied.
        case permissionDenied
        /// NSAppleScript error -600 (`procNotFound`): target app is not running.
        case appNotRunning
        /// Any other NSAppleScript error; associated value is the raw error code for logging.
        case scriptError(Int)
    }

    /// Current Automation (AppleScript) permission state for browser-based meeting detection.
    /// Updated after each `detectBrowserMeeting()` call.
    enum AutomationPermissionStatus: Equatable {
        /// No browser detection has run yet since monitoring started.
        case unknown
        /// AppleScript executed successfully in at least one browser during the last poll.
        case granted
        /// All running browsers returned NSAppleScript error -1743 during the last poll.
        case denied
        /// No supported browser was running during the last poll.
        case unavailable
    }

    // MARK: - Public State

    var detectedMeetingApp: String?
    var shouldShowRecordingPrompt = false

    /// Current Automation permission state; updated after every browser detection poll.
    /// Observe this from Settings or diagnostic views to show a permission badge.
    var automationPermissionStatus: AutomationPermissionStatus = .unknown

    /// Fired on the main thread the first time a new meeting session is discovered.
    var onMeetingDetected: ((String) -> Void)?

    /// Called on the main actor when an active meeting disappears from the detection window.
    /// Used by `MainContainerView` to auto-stop recording within 3–5 s of meeting end.
    /// Safe to set multiple times (last writer wins); nil by default.
    var onMeetingEnded: (() -> Void)?

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
        // Webex — browser-hosted meetings.
        // Use the more specific "/meet/" path so stableKey can retain the room
        // identifier (one segment) without over-capturing the host root.
        "web.webex.com/meet/",
        "webex.com/meet/",
    ]

    // MARK: - Private State

    private var timer: Timer?
    /// Prevents concurrent poll tasks from stacking when fast-poll is active.
    @ObservationIgnored private var isPollInFlight = false

    /// Key of the currently detected meeting session.
    private var activeMeetingKey: String?

    /// Key of the most recently dismissed meeting session.
    /// Prevents re-prompting for the same ongoing meeting after the user explicitly dismissed.
    /// Cleared only when that meeting fully ends (detection returns nil).
    private var dismissedMeetingKey: String?

    /// Serial queue keeps NSAppleScript calls off the main thread and serialises concurrent access.
    private let scriptQueue = DispatchQueue(label: "com.orin.meeting-detector.applescript", qos: .utility)

    /// Dedicated logger for Automation permission diagnostics.
    /// Visible in Console.app under subsystem "com.clavrit.orin", category "AutomationPermission".
    private let scriptLogger = Logger(subsystem: "com.clavrit.orin", category: "AutomationPermission")

    /// `true` once a permission-denied error has been surfaced via `ErrorManager`.
    /// Resets to `false` when permission is (re-)granted or `retryBrowserDetection()` is called,
    /// allowing the error to surface again if the situation recurs.
    @ObservationIgnored
    private var hasReportedAutomationDenial = false

    // MARK: - Dependencies

    /// Provides EventKit event data for the calendar-based detection path.
    private let calendarService: CalendarService

    // MARK: - Testing Support

    /// Overrides the EventKit query performed by `detectFromCalendar()`.
    ///
    /// **For testing only.** Set before calling `startMonitoring()` to inject synthetic
    /// `EKEvent` objects without requiring real calendar authorization.
    @ObservationIgnored
    var _calendarEventProviderOverride: ((Date, Date) -> [EKEvent])?

    /// Overrides all NSAppleScript execution in the browser detection path.
    ///
    /// **For testing only.** The closure receives the raw AppleScript source string and
    /// returns the desired `BrowserScriptOutcome`. `nil` (default) uses real execution.
    @ObservationIgnored
    var _browserScriptExecutorOverride: ((String) async -> BrowserScriptOutcome)?

    /// Overrides the set of running browser bundle IDs checked in `detectBrowserMeeting()`.
    ///
    /// **For testing only.** `nil` (default) reads from `NSWorkspace.shared.runningApplications`.
    @ObservationIgnored
    var _runningBrowserIDsOverride: Set<String>?

    // MARK: - Lifecycle

    /// Creates a `MeetingDetectorService`.
    ///
    /// - Parameter calendarService: The `CalendarService` used for EventKit queries.
    ///   Defaults to a fresh instance (starts with `status == .red`, returning empty
    ///   event arrays until calendar authorization is granted).
    init(calendarService: CalendarService = .init()) {
        self.calendarService = calendarService
    }

    @MainActor
    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    @MainActor
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isPollInFlight = false
        detectedMeetingApp = nil
        shouldShowRecordingPrompt = false
        activeMeetingKey = nil
        dismissedMeetingKey = nil
        automationPermissionStatus = .unknown
        hasReportedAutomationDenial = false
    }

    @MainActor
    func dismissPrompt() {
        shouldShowRecordingPrompt = false
        dismissedMeetingKey = activeMeetingKey
    }

    /// Switches the poll interval to 4 s while recording is active.
    ///
    /// Called by `MainContainerView` when `recordingService.isRecording` becomes `true`.
    /// A 4 s cadence allows meeting-end detection within ≤ 8 s (one miss + one hit),
    /// satisfying the 3–5 s auto-stop requirement for typical meeting-end events.
    ///
    /// No-op if monitoring has not been started yet.
    @MainActor
    func enableFastPoll() {
        guard timer != nil else { return }
        print("[AutoStop] fast poll enabled (4 s interval)")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()   // immediate check so first detection fires within ≤ 4 s, not 4+4
    }

    /// Restores the normal 30 s poll interval after recording stops.
    @MainActor
    func disableFastPoll() {
        guard timer != nil else { return }
        print("[AutoStop] fast poll disabled — restoring 30 s interval")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Re-triggers browser detection immediately after the user grants Automation permission.
    ///
    /// Resets `automationPermissionStatus` to `.unknown` and clears the denial-tracking flag
    /// so `ErrorManager` can surface the error again if Automation is still denied.
    /// Call this from the "Retry" action on the automation permission error toast.
    @MainActor
    func retryBrowserDetection() {
        hasReportedAutomationDenial = false
        automationPermissionStatus = .unknown
        poll()
    }

    // MARK: - Polling (timer fires on main thread)

    private func poll() {
        // Guard: prevent concurrent detection tasks when fast-poll fires faster than
        // a slow AppleScript/EventKit query can complete. Without this, tasks queue on
        // scriptQueue and back up under poor network or script-timeout conditions.
        guard !isPollInFlight else {
            print("[MeetingDetector] poll skipped — previous task still in flight")
            return
        }
        isPollInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let detection = await self.detectMeeting()
            await self.applyDetectionResult(detection)
            await MainActor.run { self.isPollInFlight = false }
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
    /// Returns `nil` when calendar access is denied, no events exist in the window,
    /// or no events contain a recognised meeting URL.
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

    /// Scans an `EKEvent`'s metadata fields for the first recognisable video-conference URL.
    ///
    /// Fields are checked in priority order: `EKEvent.url` → `notes` → `location`.
    ///
    /// `internal` access so the test target can exercise it directly.
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

    /// Queries each running supported browser via AppleScript for its active tab URLs.
    ///
    /// Every script outcome is handled explicitly — this method cannot fail silently:
    /// - `.urls`: parsed for meeting URLs; `automationPermissionStatus` set to `.granted`
    /// - `.permissionDenied`: logged at error level; status set to `.denied`; error surfaced once
    /// - `.appNotRunning`: logged at debug level; browser may have quit mid-poll
    /// - `.scriptError`: logged at warning level; status left unchanged
    ///
    /// `internal` access so tests can call it directly with injected hooks.
    func detectBrowserMeeting() async -> (app: String, key: String)? {
        let runningIDs = _runningBrowserIDsOverride
            ?? Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        var anyBrowserRunning = false
        var anyGranted        = false
        var anyDenied         = false
        var firstDeniedApp: String?

        // --- Chromium-family browsers ---
        for browser in chromiumBrowsers {
            guard runningIDs.contains(browser.bundleID) else { continue }
            anyBrowserRunning = true

            let outcome = await executeScript(chromiumTabScript(appName: browser.appName))
            switch outcome {
            case .urls(let urlString):
                anyGranted = true
                if let meetingURL = firstMeetingURL(in: urlString) {
                    await applyAutomationStatus(.granted, deniedApp: nil)
                    return (app: "\(browser.appName) – Meeting", key: "browser|\(meetingURL)")
                }

            case .permissionDenied:
                anyDenied = true
                if firstDeniedApp == nil { firstDeniedApp = browser.appName }
                scriptLogger.error("Automation permission denied for \(browser.appName, privacy: .public) (\(browser.bundleID, privacy: .public)): NSAppleScript error -1743 errAEEventNotPermitted. Fix: System Settings → Privacy & Security → Automation → enable Orin.")

            case .appNotRunning:
                scriptLogger.debug("\(browser.appName, privacy: .public) visible to NSWorkspace but AppleScript returned -600 (procNotFound). App may have just quit.")

            case .scriptError(let code):
                scriptLogger.warning("Unexpected AppleScript error \(code, privacy: .public) querying \(browser.appName, privacy: .public) tabs — skipping browser.")
            }
        }

        // --- Safari ---
        if runningIDs.contains("com.apple.Safari") {
            anyBrowserRunning = true

            let outcome = await executeScript(safariTabScript())
            switch outcome {
            case .urls(let urlString):
                anyGranted = true
                if let meetingURL = firstMeetingURL(in: urlString) {
                    await applyAutomationStatus(.granted, deniedApp: nil)
                    return (app: "Safari – Meeting", key: "browser|\(meetingURL)")
                }

            case .permissionDenied:
                anyDenied = true
                if firstDeniedApp == nil { firstDeniedApp = "Safari" }
                scriptLogger.error("Automation permission denied for Safari (com.apple.Safari): NSAppleScript error -1743 errAEEventNotPermitted. Fix: System Settings → Privacy & Security → Automation → enable Orin.")

            case .appNotRunning:
                scriptLogger.debug("Safari visible to NSWorkspace but AppleScript returned -600 (procNotFound).")

            case .scriptError(let code):
                scriptLogger.warning("Unexpected AppleScript error \(code, privacy: .public) querying Safari — skipping.")
            }
        }

        // --- Resolve final automation permission status ---
        if anyGranted {
            // At least one browser responded — detection is active.
            if anyDenied {
                scriptLogger.warning("Automation partially denied: some browsers blocked; meeting detection active via other browsers.")
            }
            await applyAutomationStatus(.granted, deniedApp: nil)
        } else if anyDenied {
            // Every browser that ran denied access.
            await applyAutomationStatus(.denied, deniedApp: firstDeniedApp)
        } else if !anyBrowserRunning {
            await applyAutomationStatus(.unavailable, deniedApp: nil)
        }
        // Browsers were running but all outcomes were .scriptError — leave status unchanged
        // to avoid a spurious .unavailable flip while the situation is ambiguous.

        return nil
    }

    // MARK: - AppleScript execution

    /// Dispatches NSAppleScript on the serial `scriptQueue` and returns a typed outcome.
    ///
    /// The test hook `_browserScriptExecutorOverride` bypasses real execution — inject it
    /// in unit tests to simulate any permission or error scenario without running AppleScript.
    private func executeScript(_ source: String) async -> BrowserScriptOutcome {
        if let override = _browserScriptExecutorOverride {
            return await override(source)
        }

        return await withCheckedContinuation { continuation in
            scriptQueue.async {
                var errorDict: NSDictionary?
                let script     = NSAppleScript(source: source)
                let descriptor = script?.executeAndReturnError(&errorDict)

                if let descriptor {
                    // Successful execution — return the string value (may be empty).
                    continuation.resume(returning: .urls(descriptor.stringValue ?? ""))
                    return
                }

                // Map the error code to a typed outcome.
                // NSAppleScript.errorNumber is the key for the numeric error code in the dict.
                let code = (errorDict?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
                switch code {
                case -1743:
                    continuation.resume(returning: .permissionDenied)
                case -600:
                    continuation.resume(returning: .appNotRunning)
                default:
                    continuation.resume(returning: .scriptError(code))
                }
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

    // MARK: - URL helpers

    func firstMeetingURL(in urlString: String) -> String? {
        for url in urlString.components(separatedBy: "\n") {
            for pattern in meetingURLPatterns where url.contains(pattern) {
                return stableKey(url: url, pattern: pattern)
            }
        }
        return nil
    }

    /// Produces a stable deduplication key from a raw URL and its matched pattern.
    ///
    /// Two rules govern how much of the URL path is retained:
    ///
    /// **Pattern ends with `/`** (e.g. `"zoom.us/wc/"`, `"meet.google.com/"`)
    /// → keep the pattern prefix **plus exactly one more path segment** (the meeting-room
    ///   identifier).  Any further segments — such as Zoom Web Client's trailing `/join` —
    ///   are discarded.  When nothing follows the trailing slash (e.g. after fragment
    ///   stripping `teams.microsoft.com/v2/#/calling/join` → `teams.microsoft.com/v2/`),
    ///   the pattern itself is the stable key.
    ///
    /// **Pattern does NOT end with `/`** (e.g. `"teams.microsoft.com/l/meetup-join"`)
    /// → return exactly the matched pattern portion and drop everything that follows.
    ///   This collapses opaque join-link paths like `/19%3a…/0` into a single stable key.
    ///
    /// Query strings and fragment identifiers are stripped before either rule is applied.
    func stableKey(url: String, pattern: String) -> String {
        guard let range = url.range(of: pattern) else { return String(url.prefix(80)) }
        let fromPattern = String(url[range.lowerBound...])

        // Strip query string and fragment first.
        let withoutQueryFragment = fromPattern
            .components(separatedBy: CharacterSet(charactersIn: "?#"))
            .first ?? ""

        if pattern.hasSuffix("/") {
            // Keep exactly one more path segment after the trailing slash.
            let afterPattern = String(withoutQueryFragment.dropFirst(pattern.count))
            let meetingID    = afterPattern.components(separatedBy: "/").first ?? ""
            let result: String
            if meetingID.isEmpty {
                // Nothing follows the trailing slash (e.g. fragment was stripped).
                result = withoutQueryFragment
            } else {
                result = String(withoutQueryFragment.prefix(pattern.count)) + meetingID
            }
            return String(result.prefix(80))
        } else {
            // Pattern has no trailing slash — the pattern itself is the stable identifier.
            return String(withoutQueryFragment.prefix(pattern.count).prefix(80))
        }
    }

    // MARK: - Automation permission state (main actor only)

    /// Updates `automationPermissionStatus` and surfaces a user-facing error exactly once
    /// per denial episode (not on every 30-second poll).
    ///
    /// When `status == .granted`, resets `hasReportedAutomationDenial` so future revocations
    /// can be reported again.
    @MainActor
    private func applyAutomationStatus(_ status: AutomationPermissionStatus, deniedApp: String?) {
        automationPermissionStatus = status

        if status == .granted {
            // Permission (re-)granted — future denials must be surfaced fresh.
            hasReportedAutomationDenial = false
            return
        }

        guard status == .denied, !hasReportedAutomationDenial else { return }
        hasReportedAutomationDenial = true

        let appName = deniedApp ?? "a browser"
        ErrorManager.shared.report(
            .automationPermissionDenied(app: appName),
            retryAction: { [weak self] in
                // Hop explicitly to the main actor — retryBrowserDetection is @MainActor.
                await MainActor.run { self?.retryBrowserDetection() }
            }
        )
    }

    // MARK: - State update (main actor only)

    /// Internal so the test target can drive state transitions directly.
    @MainActor
    func applyDetectionResult(_ result: (app: String, key: String)?) {
        guard let result else {
            // Meeting left the detection window (or native app exited).
            // Always clear the visible overlay state.
            guard detectedMeetingApp != nil || shouldShowRecordingPrompt else { return }
            let endedApp = detectedMeetingApp ?? "unknown"
            print("[MeetingDetector] meeting ended app='\(endedApp)' — notifying auto-stop watchdog")
            detectedMeetingApp = nil
            shouldShowRecordingPrompt = false
            onMeetingEnded?()    // auto-stop watchdog registered by MainContainerView

            // Key-reset policy:
            //
            // • If the user explicitly dismissed this meeting (`dismissedMeetingKey != nil`),
            //   clear both session keys so the same meeting key can re-trigger the overlay
            //   when the next instance starts (e.g. a new Zoom call, a rescheduled event).
            //
            // • If the meeting ended without a dismiss, KEEP `activeMeetingKey`.
            //   This prevents the same key from re-prompting if the same event briefly
            //   re-enters the calendar detection window on the next poll.
            //   In production, distinct recurring-event occurrences carry distinct
            //   `eventIdentifier` values and will produce different keys, so they do
            //   re-trigger correctly.
            if dismissedMeetingKey != nil {
                activeMeetingKey   = nil
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
