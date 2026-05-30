import AppKit
import AVFoundation
import Foundation

// MARK: - macOSAccessibilityProvider
//
// Uses CGWindowListCopyWindowInfo to inspect on-screen window titles.
//
// PERMISSION NOTE:
// kCGWindowName (window title) requires Screen Recording permission on
// macOS 12.3+.  Without it, kCGWindowName returns nil for all windows.
// This implementation degrades gracefully: when no titles are available,
// `hasWindow(appNamed:withTitleContaining:)` returns `true` if the app
// has *any* on-screen window — confirming it is running with UI, even
// if we cannot confirm a call-specific title.  This provides partial
// confidence (process-level) rather than zero.

final class macOSAccessibilityProvider: AccessibilityProvider, Service {

    // MARK: - AccessibilityProvider

    nonisolated func windowTitles(forAppNamed appName: String) -> [String] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return list.compactMap { info -> String? in
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner.localizedCaseInsensitiveContains(appName) else { return nil }
            guard let title = info[kCGWindowName as String] as? String,
                  !title.isEmpty else { return nil }
            return title
        }
    }

    nonisolated func hasWindow(appNamed appName: String, withTitleContaining keywords: [String]) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        var appHasAnyWindow = false

        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner.localizedCaseInsensitiveContains(appName) else { continue }

            appHasAnyWindow = true

            // If we have a window title, check it against keywords.
            if let title = info[kCGWindowName as String] as? String, !title.isEmpty {
                for keyword in keywords where title.localizedCaseInsensitiveContains(keyword) {
                    return true
                }
            }
        }

        // No title matched any keyword.
        // If Screen Recording permission is absent, titles will all be nil — in that
        // case we can't confirm a call window, so return false to avoid false positives.
        // The process-running signal (fromRunningProcess) will carry its own score.
        return false
    }
}

// MARK: - AVAudioActivityProvider

final class AVAudioActivityProvider: AudioActivityProvider, Service {

    /// Returns `true` when the system microphone is in use by another application.
    ///
    /// Uses `AVCaptureDevice.isInUseByAnotherApplication` which reflects whether
    /// any app outside of Orin currently holds the microphone — a reliable proxy
    /// for an active call in Teams, Zoom, Slack, FaceTime, etc.
    ///
    /// Returns `false` if no microphone device is present on the system.
    nonisolated func isMicrophoneInUseByAnotherApp() -> Bool {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.contains { $0.isInUseByAnotherApplication }
    }
}
