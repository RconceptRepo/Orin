import Foundation

// MARK: - NotificationProvider
//
// Abstracts the platform notification system (UNUserNotificationCenter on
// macOS/iOS, WinRT Notifications on Windows) from the meeting detection
// engine and recording workflow.
//
// macOS implementation: UNNotificationProvider (wraps MeetingNotificationService)
//
// Conforming types must be @MainActor-isolated because notification actions
// are dispatched to the main thread.

@MainActor
protocol NotificationProvider: AnyObject {

    // MARK: - Setup

    /// Registers notification categories and requests authorization.
    /// Safe to call multiple times — subsequent calls are no-ops.
    func configure()

    // MARK: - Meeting Notifications

    /// Posts a "Meeting Detected" notification with Start Recording / Dismiss actions.
    /// A 3-minute per-app cooldown prevents duplicate banners.
    func notifyMeetingDetected(appName: String)

    // MARK: - Recording Notifications

    /// Posts a persistent "Recording in Progress" banner with a Stop action.
    func notifyRecordingActive()

    /// Removes the "Recording in Progress" banner.
    func notifyRecordingStopped()

    // MARK: - Action Routing

    /// Called by the platform's notification delegate when the user taps an
    /// action button.  Implementations must dispatch to the `handler` on the
    /// main actor.
    ///
    /// The handler stores a `UserDefaults` flag for `startRecording` so the
    /// action survives if the app was not in memory when the notification
    /// was tapped — `MainContainerView` consumes the flag on next activation.
    var onAction: ((NotificationAction) -> Void)? { get set }
}
