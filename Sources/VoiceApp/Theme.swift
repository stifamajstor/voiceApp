import SwiftUI

/// VoiceApp's look: a slightly lifted ("pale") black with neon green accents.
enum Theme {
    /// Window background — a soft black, not pure #000.
    static let background = Color(red: 0.086, green: 0.094, blue: 0.090)   // #161816
    /// Raised surfaces (cards, rows).
    static let surface = Color(red: 0.122, green: 0.133, blue: 0.126)      // #1F2220
    static let surfaceHover = Color(red: 0.153, green: 0.169, blue: 0.157) // #272B28
    static let stroke = Color.white.opacity(0.07)

    static let neon = Color(red: 0.224, green: 1.0, blue: 0.392)           // #39FF64
    static let neonDim = neon.opacity(0.55)

    static let textPrimary = Color(white: 0.93)
    static let textSecondary = Color(white: 0.58)
    static let warning = Color(red: 1.0, green: 0.66, blue: 0.2)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)
}

extension View {
    /// Rounded raised panel used to group content in the popover.
    func themeCard(padding: CGFloat = 10) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }

    /// Soft neon halo.
    func neonGlow(_ active: Bool = true, radius: CGFloat = 8) -> some View {
        shadow(color: Theme.neon.opacity(active ? 0.55 : 0), radius: radius)
    }
}

/// Small caps section label.
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.neonDim)
    }
}

/// Outlined neon button; `prominent` fills it.
struct NeonButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        NeonButtonLabel(configuration: configuration, prominent: prominent)
    }

    private struct NeonButtonLabel: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let fillOpacity = configuration.isPressed ? 0.24 : (hovering ? 0.14 : 0.07)
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(prominent ? Theme.background : Theme.neon)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? Theme.neon : Theme.neon.opacity(fillOpacity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.neon.opacity(hovering ? 0.6 : 0.3))
                )
                .neonGlow(prominent && hovering, radius: 6)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
