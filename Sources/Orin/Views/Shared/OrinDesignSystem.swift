import SwiftUI

enum OrinThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum OrinColor {
    static let accent = Color(hex: 0x2563EB)
    static let accentHover = Color(hex: 0x1D4ED8)
    static let accentPressed = Color(hex: 0x1E40AF)
    static let success = Color(hex: 0x16A34A)
    static let warning = Color(hex: 0xF59E0B)
    static let error = Color(hex: 0xDC2626)
    static let info = Color(hex: 0x2563EB)

    static let p0 = Color(hex: 0xDC2626)
    static let p1 = Color(hex: 0xEA580C)
    static let p2 = Color(hex: 0x2563EB)
    static let p3 = Color(hex: 0x6B7280)

    static let p0Badge = Color(hex: 0xFEE2E2)
    static let p1Badge = Color(hex: 0xFFEDD5)
    static let p2Badge = Color(hex: 0xDBEAFE)
    static let p3Badge = Color(hex: 0xF3F4F6)

    static func backgroundPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x111827) : Color(hex: 0xF8F9FB)
    }

    static func backgroundSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1F2937) : Color(hex: 0xFFFFFF)
    }

    static func sidebarBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x0F172A) : Color(hex: 0xF2F4F7)
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1E293B) : Color(hex: 0xFFFFFF)
    }

    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF9FAFB) : Color(hex: 0x111827)
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x9CA3AF) : Color(hex: 0x6B7280)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x334155) : Color(hex: 0xE5E7EB)
    }
}

enum OrinSpacing {
    static let card: CGFloat = 20
    static let gap: CGFloat = 16
    static let page: CGFloat = 24
}

enum OrinRadius {
    static let card: CGFloat = 16
    static let button: CGFloat = 12
    static let input: CGFloat = 10
    static let badge: CGFloat = 999
}

enum OrinFont {
    static let pageTitle = Font.system(size: 28, weight: .semibold)
    static let sectionTitle = Font.system(size: 20, weight: .semibold)
    static let cardTitle = Font.system(size: 16, weight: .semibold)
    static let body = Font.system(size: 14)
    static let caption = Font.system(size: 12)
}

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

struct OrinCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(OrinSpacing.card)
            .background(OrinColor.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: OrinRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OrinRadius.card, style: .continuous)
                    .stroke(OrinColor.border(colorScheme), lineWidth: 1)
            }
            .shadow(color: shadowColor, radius: colorScheme == .dark ? 4 : 3, x: 0, y: 1)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.35) : Color.black.opacity(0.08)
    }
}

struct OrinPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OrinFont.body.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(configuration.isPressed ? OrinColor.accentPressed : OrinColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: OrinRadius.button, style: .continuous))
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

struct OrinSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OrinFont.body.weight(.medium))
            .foregroundStyle(OrinColor.primaryText(colorScheme))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(OrinColor.backgroundSecondary(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: OrinRadius.button, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OrinRadius.button, style: .continuous)
                    .stroke(OrinColor.border(colorScheme), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

struct OrinPageHeader<Trailing: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(OrinFont.pageTitle)
                    .foregroundStyle(OrinColor.primaryText(colorScheme))
                if let subtitle {
                    Text(subtitle)
                        .font(OrinFont.body)
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                }
            }
            Spacer()
            trailing
        }
    }
}

extension OrinPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

struct PriorityBadge: View {
    let priority: TaskPriority

    var body: some View {
        Text(priority.displayName.replacingOccurrences(of: " ", with: "\n"))
            .font(OrinFont.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(background)
            .clipShape(Capsule())
            .accessibilityLabel(priority.displayName)
    }

    private var foreground: Color {
        switch priority {
        case .p0Critical: OrinColor.p0
        case .p1High: OrinColor.p1
        case .p2Medium: OrinColor.p2
        case .p3Low: OrinColor.p3
        }
    }

    private var background: Color {
        switch priority {
        case .p0Critical: OrinColor.p0Badge
        case .p1High: OrinColor.p1Badge
        case .p2Medium: OrinColor.p2Badge
        case .p3Low: OrinColor.p3Badge
        }
    }
}
