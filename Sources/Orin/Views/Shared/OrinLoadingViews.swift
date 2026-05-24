import SwiftUI

// MARK: - Skeleton Row
// A shimmer placeholder shown while data loads or syncs.

struct OrinSkeletonRow: View {
    @State private var shimmerOffset: CGFloat = -200
    var height: CGFloat = 44
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(shimmerGradient)
            .frame(height: height)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    shimmerOffset = 300
                }
            }
    }

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.primary.opacity(0.06), location: 0),
                .init(color: Color.primary.opacity(0.12), location: 0.3 + shimmerOffset / 1000),
                .init(color: Color.primary.opacity(0.06), location: 0.6 + shimmerOffset / 1000),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Progress Step View
// Shows a labelled in-progress state with step description and spinner.

struct OrinProgressStep: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: String
    var showSpinner: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            if showSpinner {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 18, height: 18)
            }
            Text(message)
                .font(OrinFont.body)
                .foregroundStyle(OrinColor.secondaryText(colorScheme))
        }
    }
}

// MARK: - Inline Status Badge
// Compact badge for operation states (syncing, analyzing, waiting, etc.)

struct OrinStatusBadge: View {
    enum Status {
        case syncing(String)
        case done(String)
        case failed(String)
        case waiting(String)
    }
    let status: Status

    var body: some View {
        HStack(spacing: 5) {
            statusIcon
            Text(label)
                .font(OrinFont.caption.weight(.medium))
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(foreground.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .syncing:
            ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(foreground)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(foreground)
        case .waiting:
            Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(foreground)
        }
    }

    private var label: String {
        switch status {
        case .syncing(let s), .done(let s), .failed(let s), .waiting(let s): return s
        }
    }

    private var foreground: Color {
        switch status {
        case .syncing: return OrinColor.info
        case .done: return OrinColor.success
        case .failed: return OrinColor.error
        case .waiting: return OrinColor.warning
        }
    }
}

// MARK: - Drag Handle
// Grip icon shown on reorderable list rows.

struct DragHandleView: View {
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isHovering ? Color.secondary : Color.secondary.opacity(0.35))
            .frame(width: 16, height: 44)
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.12)) { isHovering = inside }
                if inside {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityLabel("Drag handle")
            .accessibilityHint("Drag to reorder this task")
    }
}

// MARK: - Drag Hint Overlay
// One-time animated banner shown to first-time users to teach drag-to-reorder.

struct DragHintBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var arrowOffset: CGFloat = 0
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Animated up-down arrow
            VStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(OrinColor.accent)
            .offset(y: arrowOffset)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    arrowOffset = 3
                }
            }

            Text("Drag the \(Image(systemName: "line.3.horizontal")) handle to reorder tasks")
                .font(OrinFont.caption)
                .foregroundStyle(OrinColor.secondaryText(colorScheme))

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(OrinColor.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(OrinColor.accent.opacity(0.2), lineWidth: 1)
        }
    }
}
