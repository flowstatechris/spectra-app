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

    // Type — fixed editorial sizes, but scaled through UIFontMetrics so every
    // label honors Dynamic Type (§13). `relativeTo` anchors the scale curve:
    // small labels track .caption, body copy .body, display .title.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular,
                      relativeTo style: UIFont.TextStyle = .body) -> Font {
        .system(size: scaled(size, style), weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium,
                     relativeTo style: UIFont.TextStyle = .body) -> Font {
        .system(size: scaled(size, style), weight: weight, design: .monospaced)
    }
    private static func scaled(_ size: CGFloat, _ style: UIFont.TextStyle) -> CGFloat {
        UIFontMetrics(forTextStyle: style).scaledValue(for: size)
    }
}

/// Four-step corner scale. Every rounded shape in the app lands on one of
/// these; previously the same visual weight was drawn at 8/9/10 or 16/18 or
/// 20/22 depending on which view drew it.
enum Radius {
    static let sm: CGFloat = 10   // chips, inline plates, small tiles
    static let md: CGFloat = 14   // receipts, thumbnails, detail boxes
    static let lg: CGFloat = 18   // message bubbles, cards
    static let xl: CGFloat = 22   // elevated sheets, the input field
}

enum Space {
    /// One outer horizontal margin for every screen. The chat header used to
    /// mix 18 (compact) and 24 (expanded), so it slid sideways on every
    /// collapse; the other tabs used 24 and the thread 18.
    static let gutter: CGFloat = 20
    static let row: CGFloat = 12   // spacing between stacked list rows
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
            .font(Theme.mono(11, .medium, relativeTo: .caption2))
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
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

// MARK: - Shimmer

/// Sweeping highlight for in-flight text — the "thinking" shimmer.
///
/// Drives off `TimelineView(.animation)` like ThinkingOrb does (no Timer, no
/// CADisplayLink to tear down; SwiftUI stops servicing it off-screen). The
/// highlight is a moving gradient handed to `foregroundStyle` rather than an
/// overlay masked by the text: a mask forces an offscreen pass every frame,
/// and this rides on top of streaming text that is already re-laying out per
/// token.
private struct TextShimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: Double = 1.7

    func body(content: Content) -> some View {
        if !active || reduceMotion {
            content.foregroundStyle(Theme.muted)
        } else {
            TimelineView(.animation) { timeline in
                content.foregroundStyle(
                    Self.sweep(at: timeline.date.timeIntervalSinceReferenceDate))
            }
        }
    }

    /// Highlight band travelling left→right, looping every `period` seconds.
    /// Runs from -0.2 to 1.2 so the band enters and exits fully off the edges
    /// instead of appearing to bounce at the ends.
    private static func sweep(at t: TimeInterval) -> LinearGradient {
        let phase = (t.truncatingRemainder(dividingBy: period) / period) * 1.4 - 0.2
        let band = 0.18
        let clamp = { (x: Double) in min(max(x, 0), 1) }
        return LinearGradient(
            stops: [
                .init(color: Theme.muted, location: 0),
                .init(color: Theme.muted, location: clamp(phase - band)),
                .init(color: Theme.ink,   location: clamp(phase)),
                .init(color: Theme.muted, location: clamp(phase + band)),
                .init(color: Theme.muted, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}

extension View {
    /// Shimmer this text while `active` — reads as "still working on it".
    /// The modifier owns the text colour either way (settling to `Theme.muted`
    /// when inactive or under Reduce Motion), so call sites must not set their
    /// own `foregroundStyle` — the inner one would win and hide the sweep.
    func shimmering(_ active: Bool = true) -> some View {
        modifier(TextShimmer(active: active))
    }
}

// MARK: - Appearance

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
