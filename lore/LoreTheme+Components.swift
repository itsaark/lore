import SwiftUI

/// A rounded surface card with a hairline edge, used for grouped content on
/// the canvas.
struct LoreCard<Content: View>: View {
    var padding: CGFloat = 18
    var cornerRadius: CGFloat = LoreTheme.cardCornerRadius
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LoreTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LoreTheme.hairline, lineWidth: 0.5)
            }
    }
}

/// Small uppercase, tracked label that introduces a section or a date.
struct LoreSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(LoreTheme.eyebrow)
            .tracking(1.2)
            .foregroundStyle(LoreTheme.secondaryInk)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Full-width hairline separator.
struct LoreHairline: View {
    var body: some View {
        Rectangle()
            .fill(LoreTheme.hairline)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// Disabled-aware pill. The base pill style has no disabled treatment, so this
/// dims it to a quiet grey capsule when the action is unavailable.
struct LoreAdaptivePillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        LorePillButtonStyle(isProminent: isProminent && isEnabled)
            .makeBody(configuration: configuration)
            .opacity(isEnabled ? 1 : 0.55)
    }
}

extension ButtonStyle where Self == LoreAdaptivePillButtonStyle {
    static var lorePillAdaptive: LoreAdaptivePillButtonStyle { LoreAdaptivePillButtonStyle() }
}

extension View {
    /// Styles a `List` or `Form` to sit on the Lore canvas with surface rows.
    func loreGroupedList() -> some View {
        scrollContentBackground(.hidden)
            .loreCanvas()
            .listRowSeparatorTint(LoreTheme.hairline)
    }

    /// Row background and separator color for a grouped `List`/`Form` row.
    func loreListRow() -> some View {
        listRowBackground(LoreTheme.surface)
            .listRowSeparatorTint(LoreTheme.hairline)
    }

    /// Text input well on the canvas.
    func loreField(minHeight: CGFloat = 54) -> some View {
        padding(.horizontal, 16)
            .frame(minHeight: minHeight)
            .background(LoreTheme.surface, in: RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LoreTheme.tileCornerRadius, style: .continuous)
                    .strokeBorder(LoreTheme.hairline, lineWidth: 0.5)
            }
    }

    /// Serif navigation bar titles on the canvas.
    func loreNavigationBar() -> some View {
        toolbarBackground(LoreTheme.canvas, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
