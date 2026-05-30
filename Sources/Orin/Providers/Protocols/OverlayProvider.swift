import Foundation

// MARK: - OverlayProvider
//
// Abstracts the floating recording widget from business logic.
//
// macOS implementation: NSPanelOverlayProvider (delegates to
//   FloatingRecordingWidgetWindowManager, which handles NSPanel + SwiftUI).
//
// A Windows implementation would use a WinUI flyout or a system tray icon
// with live data — without touching any NSPanel code.
//
// The protocol is @MainActor because overlay management is UI work.

@MainActor
protocol OverlayProvider: AnyObject {

    /// Shows the floating recording widget above all other windows.
    ///
    /// Implementations must:
    ///  - Remain visible when the host application is minimised or deactivated.
    ///  - Appear on the same screen as the user's current focus point.
    ///  - Support being dragged to any position.
    ///  - Work in full-screen spaces.
    ///
    /// - Parameters:
    ///   - recordingService: Observable source of truth for duration and
    ///     transcript preview.  The widget binds directly to this service.
    ///   - onStop: Called when the user taps the stop button in the widget.
    func showRecordingWidget(
        recordingService: RecordingService,
        onStop: @escaping () -> Void
    )

    /// Hides (but does not destroy) the recording widget.
    /// Subsequent `showRecordingWidget` calls must re-show it.
    func hideRecordingWidget()
}
