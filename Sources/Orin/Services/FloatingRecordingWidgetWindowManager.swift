import AppKit
import SwiftUI

// MARK: - FloatingRecordingWidgetWindowManager
//
// Manages the always-on-top NSPanel that shows recording status above all windows,
// including full-screen spaces on external monitors.
//
// Widget behaviour guarantees:
//   • Always on top         — NSWindowLevel.floating + orderFrontRegardless
//   • Draggable             — isMovableByWindowBackground = true
//   • Multi-monitor         — Placed on the screen containing the cursor on first show;
//                             subsequent drags persist via setFrameAutosaveName
//   • Full-screen support   — collectionBehavior .fullScreenAuxiliary
//   • App minimised/hidden  — hidesOnDeactivate = false keeps it visible

@MainActor
final class FloatingRecordingWidgetWindowManager {
    static let shared = FloatingRecordingWidgetWindowManager()

    private var panel: NSPanel?

    private init() {}

    // MARK: - Show / Hide

    func show(recordingService: RecordingService, onStop: @escaping () -> Void) {
        if panel == nil {
            let newPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            newPanel.isFloatingPanel             = true
            newPanel.level                       = .floating
            // .canJoinAllSpaces — panel follows to every Space on every monitor.
            // .fullScreenAuxiliary — panel appears over full-screen apps.
            newPanel.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.hidesOnDeactivate           = false   // visible even when Orin loses focus
            newPanel.isMovableByWindowBackground = true    // drag anywhere by clicking background
            newPanel.titleVisibility             = .hidden
            newPanel.titlebarAppearsTransparent  = true
            newPanel.backgroundColor             = .clear
            newPanel.isOpaque                    = false
            newPanel.minSize                     = NSSize(width: 220, height: 52)
            newPanel.maxSize                     = NSSize(width: 360, height: 120)
            // Persist drag position across app restarts.
            newPanel.setFrameAutosaveName("OrinFloatingRecordingWidget")

            // Place on the screen containing the mouse cursor, not the primary
            // display.  This ensures the widget appears where the user is working
            // on a multi-monitor setup.  If autosave has a saved frame, macOS will
            // restore it to its last position on the next setFrameAutosaveName call.
            placeOnActiveScreen(newPanel)

            self.panel = newPanel
        }

        // Always refresh content so the new onStop closure is wired up.
        panel?.contentView = NSHostingView(
            rootView: RecordingWidgetView(recordingService: recordingService, onStop: onStop)
        )
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Helpers

    /// Positions `panel` near the top of the screen that currently contains
    /// the mouse cursor.  Falls back to the main screen if the cursor position
    /// cannot be resolved.
    private func placeOnActiveScreen(_ panel: NSPanel) {
        let cursor = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            NSMouseInRect(cursor, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first!

        let panelSize = panel.frame.size
        // Position at 80 % of screen height — visible but out of the way.
        let origin = NSPoint(
            x: targetScreen.visibleFrame.midX - panelSize.width / 2,
            y: targetScreen.visibleFrame.minY + targetScreen.visibleFrame.height * 0.80
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - OverlayProvider conformance

extension FloatingRecordingWidgetWindowManager: OverlayProvider {
    func showRecordingWidget(
        recordingService: RecordingService,
        onStop: @escaping () -> Void
    ) {
        show(recordingService: recordingService, onStop: onStop)
    }

    func hideRecordingWidget() {
        hide()
    }
}
