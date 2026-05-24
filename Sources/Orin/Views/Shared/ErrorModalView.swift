import SwiftUI

// MARK: - Error Modal View

/// Full-modal alert for `.critical` severity errors that require explicit user acknowledgment.
/// Presented as a centred card over a semi-transparent backdrop.
struct ErrorModalView: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: ErrorModalItem
    var onDismiss: () -> Void

    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 0) {
            // Icon + header block
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(OrinColor.error.opacity(0.1))
                        .frame(width: 64, height: 64)
                    Image(systemName: item.error.systemImageName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(OrinColor.error)
                }

                VStack(spacing: 8) {
                    Text(item.error.errorTitle)
                        .font(OrinFont.sectionTitle)
                        .foregroundStyle(OrinColor.primaryText(colorScheme))
                        .multilineTextAlignment(.center)

                    if !item.error.errorMessage.isEmpty {
                        Text(item.error.errorMessage)
                            .font(OrinFont.body)
                            .foregroundStyle(OrinColor.secondaryText(colorScheme))
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                    }
                }
            }
            .padding(.top, 28)
            .padding(.horizontal, 24)

            Spacer(minLength: 24)

            // Recovery actions
            VStack(spacing: 10) {
                ForEach(item.error.recoveryActions) { action in
                    recoveryButton(action)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .frame(width: 380)
        .frame(minHeight: 240)
        .background(OrinColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: OrinRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OrinRadius.card, style: .continuous)
                .stroke(OrinColor.border(colorScheme), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.3), radius: 48, x: 0, y: 12)
    }

    @ViewBuilder
    private func recoveryButton(_ action: ErrorRecoveryAction) -> some View {
        switch action {
        case .dismiss:
            Button("Dismiss", action: onDismiss)
                .buttonStyle(OrinSecondaryButtonStyle())
                .frame(maxWidth: .infinity)

        case .retry:
            Button {
                guard !isRetrying else { return }
                isRetrying = true
                let retryAction = item.retryAction
                Task {
                    await retryAction?()
                    await MainActor.run {
                        isRetrying = false
                        onDismiss()
                    }
                }
            } label: {
                if isRetrying {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.75)
                        Text("Retrying…")
                    }
                    .frame(height: 36)
                    .padding(.horizontal, 14)
                } else {
                    Text("Try Again")
                }
            }
            .buttonStyle(OrinPrimaryButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(isRetrying)

        case .openSystemSettingsPrivacy:
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                    NSWorkspace.shared.open(url)
                }
                onDismiss()
            }
            .buttonStyle(OrinPrimaryButtonStyle())
            .frame(maxWidth: .infinity)

        case .openSystemSettings:
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:") {
                    NSWorkspace.shared.open(url)
                }
                onDismiss()
            }
            .buttonStyle(OrinPrimaryButtonStyle())
            .frame(maxWidth: .infinity)
        }
    }
}
