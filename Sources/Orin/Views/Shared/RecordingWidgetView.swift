import SwiftUI

struct RecordingWidgetView: View {
    @Bindable var recordingService: RecordingService
    var onStop: () -> Void

    var body: some View {
        if let error = recordingService.errorMessage {
            errorBanner(error)
        } else {
            recordingCapsule
        }
    }

    private var recordingCapsule: some View {
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

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(OrinColor.error)
            Text(message)
                .font(OrinFont.caption)
                .foregroundStyle(OrinColor.error)
                .lineLimit(3)
            Spacer()
            Button {
                recordingService.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(width: 280)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
        .accessibilityLabel("Recording error: \(message)")
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
