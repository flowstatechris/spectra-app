import SwiftUI

/// Editorial design system (from context/spectra-architecture.html):
/// warm paper / ink, one restrained blue accent, a serif-display + mono-label
/// type stack. Theme-aware; zero bundled fonts (New York + SF Mono stand in
/// for Instrument Serif + Geist Mono).
enum Theme {
    // Colors — dynamic light/dark, paper inverts to near-black.
    static let paper   = dyn(light: 0xF8F8F6, dark: 0x0E0E0F)
    static let surface = dyn(light: 0xFFFFFF, dark: 0x17171A)
    static let plate   = dyn(light: 0xEFEEEA, dark: 0x202024)   // code plates
    static let ink     = dyn(light: 0x111111, dark: 0xF0EFE9)
    static let muted   = dyn(light: 0x6E6E6E, dark: 0x8F8F8F)
    static let hairline = dyn(light: 0xE2E1DC, dark: 0x2A2A2E)
    static let accent  = dyn(light: 0x2E5AA8, dark: 0x7AA2E8)
    static let danger  = dyn(light: 0xB23A3A, dark: 0xE8807A)
    static let ok      = dyn(light: 0x3B7A4B, dark: 0x74C489)

    private static func dyn(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }

    // Type
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

private extension UIColor {
    convenience init(rgb: Int) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Reusable pieces

/// Mono, uppercase, wide-tracked section label — the editorial "eyebrow".
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.muted
    init(_ text: String, color: Color = Theme.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(11, .medium))
            .tracking(2.2)
            .foregroundStyle(color)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

/// Full-bleed paper background.
struct PaperBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Theme.paper.ignoresSafeArea())
    }
}
extension View { func paper() -> some View { modifier(PaperBackground()) } }

/// Elevated card: surface + hairline border, optional accent edge.
struct CardSurface: ViewModifier {
    var border: Color = Theme.hairline
    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(border, lineWidth: 1))
    }
}
extension View {
    func card(border: Color = Theme.hairline) -> some View { modifier(CardSurface(border: border)) }
}

/// Ink-filled primary pill.
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(14, .semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.paper)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Theme.ink, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Hairline-outline secondary pill.
struct OutlineButton: ButtonStyle {
    var tint: Color = Theme.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(13, .medium))
            .foregroundStyle(tint)
            .padding(.vertical, 11).padding(.horizontal, 16)
            .background(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
