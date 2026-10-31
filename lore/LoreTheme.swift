import SwiftUI

/// Lore's monochrome visual language: near-black canvas, white serif display
/// type, and photos as the only source of color.
enum LoreTheme {
    static let canvas = Color(white: 0.035)
    static let surface = Color(white: 0.09)
    static let raisedSurface = Color(white: 0.14)
    static let hairline = Color.white.opacity(0.12)

    static let ink = Color.white
    static let secondaryInk = Color.white.opacity(0.62)
    static let tertiaryInk = Color.white.opacity(0.36)

    /// Muted warm tone for errors so they stay legible without breaking the
    /// black-and-white palette.
    static let attention = Color(red: 1, green: 0.62, blue: 0.55)

    static let tileCornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 22

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }

    static func title(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .serif).weight(.semibold)
    }

    static func caption(_ style: Font.TextStyle = .subheadline) -> Font {
        .system(style, design: .serif).italic()
    }

    static let body = Font.system(.body, design: .serif)
    static let label = Font.footnote.weight(.semibold)
    static let eyebrow = Font.caption.weight(.semibold)
}

/// White capsule call-to-action used for the single primary action on a screen.
struct LorePillButtonStyle: ButtonStyle {
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .foregroundStyle(isProminent ? Color.black : LoreTheme.ink)
            .background {
                Capsule()
                    .fill(isProminent ? LoreTheme.ink : LoreTheme.raisedSurface)
            }
            .overlay {
                if !isProminent {
                    Capsule().strokeBorder(LoreTheme.hairline)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LorePillButtonStyle {
    static var lorePill: LorePillButtonStyle { LorePillButtonStyle() }
    static var lorePillSecondary: LorePillButtonStyle { LorePillButtonStyle(isProminent: false) }
}

extension View {
    /// Applies the Lore canvas behind a full screen.
    func loreCanvas() -> some View {
        background(LoreTheme.canvas.ignoresSafeArea())
    }
}
