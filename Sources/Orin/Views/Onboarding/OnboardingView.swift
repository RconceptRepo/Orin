import AVFoundation
import EventKit
import Speech
import SwiftUI

// MARK: - Entry point

/// Shown once on first launch to request all needed permissions and orient the user.
struct OnboardingView: View {
    @AppStorage("orin.hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var step = 0
    @Environment(\.colorScheme) private var colorScheme

    private let steps: [OnboardingStep] = [
        .welcome, .calendar, .microphone, .ready
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { i in
                    Circle()
                        .fill(i <= step ? OrinColor.accent : Color.secondary.opacity(0.25))
                        .frame(width: 8, height: 8)
                        .animation(.spring(duration: 0.3), value: step)
                }
            }
            .padding(.top, 32)

            Spacer()

            // Content
            Group {
                switch steps[step] {
                case .welcome:    WelcomeStep()
                case .calendar:   CalendarPermissionStep()
                case .microphone: MicPermissionStep()
                case .ready:      ReadyStep()
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal:   .move(edge: .leading).combined(with: .opacity)
            ))
            .id(step)

            Spacer()

            // Navigation
            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                        .buttonStyle(OrinSecondaryButtonStyle())
                }
                Spacer()
                Button(step < steps.count - 1 ? "Continue" : "Get Started") {
                    if step < steps.count - 1 {
                        withAnimation { step += 1 }
                    } else {
                        hasCompletedOnboarding = true
                    }
                }
                .buttonStyle(OrinPrimaryButtonStyle())
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 620, height: 520)
        .background(OrinColor.backgroundPrimary(colorScheme))
    }

    private enum OnboardingStep { case welcome, calendar, microphone, ready }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(OrinColor.accent)

            Text("Welcome to Orin")
                .font(.system(size: 32, weight: .bold))

            Text("Your local-first Personal Execution OS.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "checklist",           color: .green,  text: "Tasks, backlog, and daily reflow")
                FeatureRow(icon: "calendar",            color: .blue,   text: "EventKit calendar sync")
                FeatureRow(icon: "video",               color: .purple, text: "Meeting detection + live transcription")
                FeatureRow(icon: "lock.shield",         color: .orange, text: "On-device encrypted Vault")
                FeatureRow(icon: "cpu",                 color: OrinColor.accent, text: "Local-first AI via Ollama")
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 60)
    }
}

// MARK: - Calendar permission

private struct CalendarPermissionStep: View {
    @State private var calendarService = ServiceContainer.shared.resolve(CalendarService.self)
    @State private var status: CalendarPermissionStepStatus = .idle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 52))
                .foregroundStyle(.blue)

            Text("Calendar Access")
                .font(.system(size: 26, weight: .bold))

            Text("Orin reads your local EventKit calendar to show meetings alongside tasks and detect video calls. No data leaves your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            switch status {
            case .idle:
                Button {
                    Task { await requestCalendar() }
                } label: {
                    Label("Grant Calendar Access", systemImage: "calendar")
                        .frame(minWidth: 220)
                }
                .buttonStyle(OrinPrimaryButtonStyle())

            case .requesting:
                ProgressView("Requesting access…")

            case .granted:
                Label("Calendar access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)

            case .denied:
                VStack(spacing: 10) {
                    Label("Access was denied", systemImage: "xmark.circle.fill")
                        .foregroundStyle(OrinColor.error)
                    Text("Open System Settings → Privacy & Security → Calendars and enable Orin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                    .buttonStyle(OrinSecondaryButtonStyle())
                }
            }
        }
        .padding(.horizontal, 60)
        .onAppear {
            // Auto-request on appearance; skip if already decided
            let current = EKEventStore.authorizationStatus(for: .event)
            switch current {
            case .fullAccess, .authorized:
                status = .granted
            case .denied, .restricted:
                status = .denied
            case .notDetermined, .writeOnly:
                Task { await requestCalendar() }
            @unknown default:
                break
            }
        }
    }

    private func requestCalendar() async {
        status = .requesting
        await calendarService.requestPermission()
        let current = EKEventStore.authorizationStatus(for: .event)
        switch current {
        case .fullAccess, .authorized:
            status = .granted
            await calendarService.syncEvents()
        case .denied, .restricted:
            status = .denied
        default:
            status = .idle
        }
    }

    private enum CalendarPermissionStepStatus { case idle, requesting, granted, denied }
}

// MARK: - Microphone permission

private struct MicPermissionStep: View {
    @State private var micStatus: PermStatus = .idle
    @State private var speechStatus: PermStatus = .idle

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.purple)

            Text("Microphone & Transcription")
                .font(.system(size: 26, weight: .bold))

            Text("Orin records and transcribes meetings on-device via Apple Speech Recognition. Audio stays on your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            VStack(spacing: 10) {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    status: micStatus,
                    action: { Task { await requestMic() } }
                )
                PermissionRow(
                    icon: "waveform",
                    title: "Speech Recognition",
                    status: speechStatus,
                    action: { Task { await requestSpeech() } }
                )
            }
            .padding(.horizontal, 40)
        }
        .padding(.horizontal, 60)
        .onAppear {
            checkCurrentStatus()
            Task {
                await requestMic()
                await requestSpeech()
            }
        }
    }

    private func checkCurrentStatus() {
        micStatus    = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .idle
        speechStatus = SFSpeechRecognizer.authorizationStatus() == .authorized ? .granted : .idle
    }

    private func requestMic() async {
        micStatus = .requesting
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .denied
    }

    private func requestSpeech() async {
        speechStatus = .requesting
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
        speechStatus = SFSpeechRecognizer.authorizationStatus() == .authorized ? .granted : .denied
    }

    enum PermStatus { case idle, requesting, granted, denied }
}

// MARK: - Ready

private struct ReadyStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("You're all set!")
                .font(.system(size: 32, weight: .bold))

            VStack(alignment: .leading, spacing: 12) {
                InfoRow(icon: "bolt.badge.clock",      color: .green,  title: "Quick Capture",      detail: "Press ⌃⌥Space from anywhere")
                InfoRow(icon: "video.badge.waveform",  color: .purple, title: "Meeting Recording",  detail: "Banner appears when a call starts")
                InfoRow(icon: "brain",                 color: OrinColor.accent, title: "AI Summary", detail: "Configure Ollama or an API key in Settings")
                InfoRow(icon: "mic.slash",             color: .orange, title: "Siri Shortcuts",     detail: "Available after App Store distribution")
                InfoRow(icon: "safari",                color: .blue,   title: "Browser Detection",  detail: "Approve Apple Events when first prompted")
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Reusable sub-views

private struct FeatureRow: View {
    let icon: String; let color: Color; let text: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 28)
            Text(text)
                .font(.body)
        }
    }
}

private struct InfoRow: View {
    let icon: String; let color: Color; let title: String; let detail: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionRow: View {
    let icon: String; let title: String
    let status: MicPermissionStep.PermStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(statusColor)
            Text(title)
            Spacer()
            switch status {
            case .idle:
                Button("Allow", action: action)
            case .requesting:
                ProgressView().scaleEffect(0.7)
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .denied:
                Label("Denied", systemImage: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(OrinColor.error)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        switch status {
        case .idle: .secondary
        case .requesting: .blue
        case .granted: .green
        case .denied: OrinColor.error
        }
    }
}
