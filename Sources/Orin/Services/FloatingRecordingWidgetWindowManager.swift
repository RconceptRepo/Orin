import AppKit
import SwiftUI

@MainActor
final class FloatingRecordingWidgetWindowManager {
    static let shared = FloatingRecordingWidgetWindowManager()

    private var panel: NSPanel?

    private init() {}

    func show(recordingService: RecordingService, onStop: @escaping () -> Void) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.minSize = NSSize(width: 220, height: 52)
            panel.maxSize = NSSize(width: 360, height: 120)
            panel.contentView = NSHostingView(
                rootView: RecordingWidgetView(recordingService: recordingService, onStop: onStop)
            )
            panel.setFrameAutosaveName("OrinFloatingRecordingWidget")
            panel.center()
            self.panel = panel
        }

        panel?.contentView = NSHostingView(
            rootView: RecordingWidgetView(recordingService: recordingService, onStop: onStop)
        )
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
