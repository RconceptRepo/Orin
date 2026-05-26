import SwiftUI

// MARK: - Error Toast View

/// Non-intrusive bottom toast shown for `.medium` and `.high` severity errors.
/// Auto-dismisses for medium severity; persists until dismissed or retried for high.
struct ErrorToastView: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: ErrorToastItem
    var onDismiss: () -> Void

    @State private var isRetrying = false

    var body: some View {
        HStack(spacing: 12) {
            // Category icon
            Image(systemName: item.error.systemImageName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)

            // Title + message
            VStack(alignment: .leading, spacing: 2) {
                Text(item.error.errorTitle)
                    .font(OrinFont.body.weight(.semibold))
                    .foregroundStyle(OrinColor.primaryText(colorScheme))

                if !item.error.errorMessage.isEmpty {
                    Text(item.error.errorMessage)
                        .font(OrinFont.caption)
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            // Actions
            HStack(spacing: 10) {
                // Deep-link shortcut: shown when the error includes an Automation Settings action.
                if item.error.recoveryActions.contains(.openSystemSettingsAutomation) {
                    Button("Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(OrinFont.caption.weight(.semibold))
                    .foregroundStyle(OrinColor.accent)
                }

                if item.retryAction != nil, item.error.isRetryable {
                    Button {
                        guard !isRetrying else { return }
                        isRetrying = true
                        let action = item.retryAction
                        Task {
                            await action?()
                            await MainActor.run {
                                isRetrying = false
                                onDismiss()
                            }
                        }
                    } label: {
                        if isRetrying {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 36)
                        } else {
                            Text("Retry")
                                .font(OrinFont.caption.weight(.semibold))
                                .foregroundStyle(OrinColor.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRetrying)
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(OrinColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: OrinRadius.button, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OrinRadius.button, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.14),
            radius: 14, x: 0, y: 4
        )
        .frame(maxWidth: 460)
    }

    private var iconColor: Color {
        switch item.error.severity {
        case .low, .medium: OrinColor.warning
        case .high, .critical: OrinColor.error
        }
    }

    private var borderColor: Color {
        switch item.error.severity {
        case .low, .medium: OrinColor.warning.opacity(0.4)
        case .high, .critical: OrinColor.error.opacity(0.4)
        }
    }
}

// MARK: - Error Overlay Modifier

/// Applies the full error-presentation stack (toast + modal) to any view.
/// Apply once at the root — `MainContainerView` — using `.errorHandlingOverlay()`.
struct ErrorOverlayModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Toast layer — bottom-centre, slides in from below
            .overlay(alignment: .bottom) {
                ToastOverlayContent()
            }
            // Modal layer — full-window backdrop + centred card
            .overlay {
                ModalOverlayContent()
            }
    }
}

extension View {
    /// Attach the centralised error-handling overlay to this view.
    func errorHandlingOverlay() -> some View {
        modifier(ErrorOverlayModifier())
    }
}

// MARK: - Internal overlay sub-views
// Separate structs so @Observable tracking works per-render without property wrappers.

private struct ToastOverlayContent: View {
    // Reading ErrorManager.shared properties in body registers @Observable tracking.
    var body: some View {
        let manager = ErrorManager.shared
        if let toast = manager.activeToast {
            ErrorToastView(item: toast) {
                manager.dismissToast()
            }
            .padding(.bottom, 24)
            .padding(.horizontal, 24)
            .transition(
                .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                )
            )
            .id(toast.id)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: toast.id)
        }
    }
}

private struct ModalOverlayContent: View {
    var body: some View {
        let manager = ErrorManager.shared
        if let modal = manager.activeModal {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .transition(.opacity)

                ErrorModalView(item: modal) {
                    manager.dismissModal()
                }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.94).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
            .animation(.easeInOut(duration: 0.25), value: modal.id)
            .id(modal.id)
        }
    }
}
