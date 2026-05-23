import AppKit
import Foundation
import Observation

@Observable
final class MeetingDetectorService: Service {

    // MARK: - Public State (main-thread)

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

    private let meetingURLPatterns = [
        "meet.google.com/",
        "zoom.us/j/",
        "zoom.us/s/",
        "teams.live.com",
        "teams.microsoft.com/v2/",
    ]

    // MARK: - Private State

    private var timer: Timer?
    /// Tracks the current meeting session so repeated polls don't re-fire the callback.
    private var activeMeetingKey: String?
    /// Serial queue keeps NSAppleScript calls off the main thread and prevents concurrent access.
    private let scriptQueue = DispatchQueue(label: "com.orin.meeting-detector.applescript", qos: .utility)

    // MARK: - Lifecycle

    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        activeMeetingKey = nil
    }

    func dismissPrompt() {
        shouldShowRecordingPrompt = false
        activeMeetingKey = nil
    }

    // MARK: - Polling (timer fires on main thread)

    private func poll() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let detection = await self.detectMeeting()
            self.applyDetectionResult(detection)
        }
    }

    // MARK: - Detection pipeline (background-safe)

    private func detectMeeting() async -> (app: String, key: String)? {
        if let native = detectNativeApp() { return native }
        return await detectBrowserMeeting()
    }

    private func detectNativeApp() -> (app: String, key: String)? {
        let running = NSWorkspace.shared.runningApplications
        for config in nativeApps {
            guard let match = running.first(where: { $0.bundleIdentifier == config.bundleID }) else { continue }
            // For Slack, only surface if a Huddle or call window is actually on-screen.
            if config.bundleID == "com.tinyspeck.slackmacgap", !slackHasActiveCall() { continue }
            return (app: match.localizedName ?? config.displayName, key: "\(config.bundleID)|active")
        }
        return nil
    }

    /// Best-effort check using CGWindowList; silently fails if Screen Recording permission is absent.
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

    private func firstMeetingURL(in urlString: String) -> String? {
        for url in urlString.components(separatedBy: "\n") {
            for pattern in meetingURLPatterns where url.contains(pattern) {
                return stableKey(url: url, pattern: pattern)
            }
        }
        return nil
    }

    /// Strips query-string and fragment so the same meeting URL deduplicates across polls.
    private func stableKey(url: String, pattern: String) -> String {
        guard let range = url.range(of: pattern) else { return String(url.prefix(80)) }
        let path = String(url[range.lowerBound...])
            .components(separatedBy: CharacterSet(charactersIn: "?#"))
            .first ?? ""
        return String(path.prefix(80))
    }

    // MARK: - State update (always dispatched to main thread)

    private func applyDetectionResult(_ result: (app: String, key: String)?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard let result else {
                if self.detectedMeetingApp != nil {
                    self.detectedMeetingApp = nil
                    self.activeMeetingKey = nil
                }
                return
            }

            // Dedup: skip if this is the same ongoing meeting session
            guard result.key != self.activeMeetingKey else { return }

            self.activeMeetingKey = result.key
            self.detectedMeetingApp = result.app
            self.shouldShowRecordingPrompt = true
            self.onMeetingDetected?(result.app)
        }
    }
}
