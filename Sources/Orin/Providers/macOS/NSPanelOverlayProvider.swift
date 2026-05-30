import AppKit
import Foundation

// MARK: - NSPanelOverlayProvider
//
// macOS OverlayProvider implementation.
// Thin delegation layer over FloatingRecordingWidgetWindowManager.
// No NSPanel code lives here — that stays in the window manager.

@MainActor
final class NSPanelOverlayProvider: OverlayProvider, Service {

    private let windowManager = FloatingRecordingWidgetWindowManager.shared

    func showRecordingWidget(
        recordingService: RecordingService,
        onStop: @escaping () -> Void
    ) {
        windowManager.show(recordingService: recordingService, onStop: onStop)
    }

    func hideRecordingWidget() {
        windowManager.hide()
    }
}
