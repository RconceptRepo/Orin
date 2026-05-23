import SwiftUI

struct PlaceholderModuleView: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let systemImage: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(OrinColor.accent)
            Text(title)
                .font(OrinFont.sectionTitle)
                .foregroundStyle(OrinColor.primaryText(colorScheme))
            Text(message)
                .font(OrinFont.body)
                .foregroundStyle(OrinColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(OrinPrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(OrinColor.backgroundPrimary(colorScheme))
    }
}
