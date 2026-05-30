import Foundation

// MARK: - AccessibilityProvider
//
// Abstracts window-inspection APIs (CGWindowList on macOS, UIAutomation on
// Windows) from the meeting detection engine.
//
// macOS implementation: macOSAccessibilityProvider
// Notes:
//   - kCGWindowName (window title) requires Screen Recording permission on
//     macOS 12.3+.  Implementations must return [] / false gracefully when
//     the permission is absent.
//   - All methods are synchronous and safe to call from any thread.

protocol AccessibilityProvider: AnyObject, Sendable {

    /// Returns all visible window titles owned by any application whose
    /// displayed name contains `appName` (case-insensitive).
    ///
    /// Returns an empty array if the Screen Recording permission is not
    /// granted or if no matching windows are on screen.
    func windowTitles(forAppNamed appName: String) -> [String]

    /// Returns `true` if any on-screen window owned by `appName` has a
    /// title that contains at least one of `keywords` (case-insensitive).
    ///
    /// Fallback (no Screen Recording permission): returns `true` if the
    /// application has *any* on-screen window, regardless of title —
    /// indicating the process is at least running with visible UI.
    func hasWindow(appNamed appName: String, withTitleContaining keywords: [String]) -> Bool
}

// MARK: - AudioActivityProvider
//
// Abstracts microphone-activity inspection from the detection engine.
// Separate from SystemAudioProvider (which handles recording) because
// activity detection is a lightweight, read-only operation that does
// not start any capture pipeline.
//
// macOS implementation: AVAudioActivityProvider

protocol AudioActivityProvider: AnyObject, Sendable {

    /// Returns `true` if the system microphone is currently claimed by
    /// any application other than Orin.
    ///
    /// Uses `AVCaptureDevice.isInUseByAnotherApplication`.  Returns
    /// `false` when no microphone is available.
    func isMicrophoneInUseByAnotherApp() -> Bool
}
