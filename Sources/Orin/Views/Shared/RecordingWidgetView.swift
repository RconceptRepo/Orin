import SwiftUI

struct RecordingWidgetView: View {
    @Bindable var recordingService: RecordingService
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(OrinColor.error)
                .frame(width: 10, height: 10)
                .opacity(recordingService.isRecording ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(recordingService.isRecording ? "Listening" : "Stopped")
                    .font(OrinFont.body.weight(.semibold))
                Text(recordingService.durationText)
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(width: 220, height: 52)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
        .accessibilityLabel("Meeting recording widget")
    }
}

struct MeetingRecordingPromptView: View {
    let appName: String
    var onStart: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "record.circle")
                        .foregroundStyle(OrinColor.error)
                    Text("Meeting Detected")
                        .font(OrinFont.cardTitle)
                    Spacer()
                }
                Text("\(appName) appears active. Ensure all participants are aware of recording.")
                    .font(OrinFont.body)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(OrinSecondaryButtonStyle())
                    Button("Start Listening", action: onStart)
                        .buttonStyle(OrinPrimaryButtonStyle())
                }
            }
        }
        .frame(width: 360)
    }
}
