import SwiftUI

struct OrinMenuBarView: View {
    @State private var recordingService = ServiceContainer.shared.resolve(RecordingService.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Orin Engine")
                .font(.headline)

            Divider()

            Button("Quick Capture") {
                QuickCaptureWindowManager.shared.toggle()
            }

            Button("Today's Summary") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(recordingService.isRecording ? "Stop Recording" : "Start Recording") {
                if recordingService.isRecording {
                    recordingService.stopRecording()
                } else {
                    recordingService.startRecording()
                }
            }
            Button("Reflow Day") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Lock Vault") {
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Open Orin") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit Orin") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
