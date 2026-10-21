import SwiftUI

/// The type scale (Android `ui/theme/Type.kt`, Windows `Text.*` styles). Display/headline use Fraunces; the rest Inter.
///
/// Apply with the view modifiers: `Text("Movies").vHeadlineLarge()`, or generically `.vText(.titleSmall)`.
/// Each sets the font, line height, letter spacing and the default `Theme.text` color (override with
/// `.foregroundStyle(...)` after it).
public enum VTextStyle: CaseIterable, Sendable {
    case displayLarge, displayMedium, displaySmall
    case headlineLarge, headlineMedium, headlineSmall
    case titleLarge, titleMedium, titleSmall
    case bodyLarge, bodyMedium, bodySmall
    case labelLarge, labelMedium, labelSmall

    /// Point size.
    public var size: CGFloat {
        switch self {
        case .displayLarge: return 48
        case .displayMedium: return 38
        case .displaySmall: return 30
        case .headlineLarge: return 28
        case .headlineMedium: return 24
        case .headlineSmall: return 20
        case .titleLarge: return 19
        case .titleMedium: return 16
        case .titleSmall: return 14
        case .bodyLarge: return 16
        case .bodyMedium: return 14
        case .bodySmall: return 12
        case .labelLarge: return 14
        case .labelMedium: return 12
        case .labelSmall: return 11
        }
    }

    /// Line height in points.
    public var lineHeight: CGFloat {
        switch self {
        case .displayLarge: return 54
        case .displayMedium: return 44
        case .displaySmall: return 36
        case .headlineLarge: return 34
        case .headlineMedium: return 30
        case .headlineSmall: return 26
        case .titleLarge: return 26
        case .titleMedium: return 22
        case .titleSmall: return 20
        case .bodyLarge: return 24
        case .bodyMedium: return 21
        case .bodySmall: return 17
        case .labelLarge: return 20
        case .labelMedium: return 16
        case .labelSmall: return 14
        }
    }

    /// Letter spacing in em.
    public var trackingEm: CGFloat {
        switch self {
        case .displayLarge, .displayMedium: return -0.02
        case .displaySmall: return -0.015
        case .headlineLarge, .headlineMedium, .headlineSmall: return -0.01
        case .labelLarge: return 0.01
        case .labelMedium: return 0.02
        case .labelSmall: return 0.06
        default: return 0
        }
    }

    /// True for the Fraunces styles (display + headline).
    public var isSerif: Bool {
        switch self {
        case .displayLarge, .displayMedium, .displaySmall, .headlineLarge, .headlineMedium, .headlineSmall: return true
        default: return false
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .bodyLarge, .bodyMedium, .bodySmall: return .regular
        default: return .semibold
        }
    }

    /// The font for this style.
    public var font: Font { isSerif ? Fonts.serif(size) : Fonts.sans(size, weight) }

    /// Extra spacing between lines to reach `lineHeight` (Inter/Fraunces natural line height ≈ 1.21 × size).
    public var lineSpacing: CGFloat { max(0, lineHeight - size * 1.21) }
}

private struct VTextModifier: ViewModifier {
    let style: VTextStyle
    let color: Color?
    func body(content: Content) -> some View {
        content
            .font(style.font)
            .tracking(style.trackingEm * style.size)
            .lineSpacing(style.lineSpacing)
            .foregroundStyle(color ?? Theme.text)
    }
}

public extension View {
    /// Applies a type-scale style (font, line height, tracking) and a color (default `Theme.text`).
    func vText(_ style: VTextStyle, color: Color? = nil) -> some View { modifier(VTextModifier(style: style, color: color)) }

    func vDisplayLarge(_ color: Color? = nil) -> some View { vText(.displayLarge, color: color) }
    func vDisplayMedium(_ color: Color? = nil) -> some View { vText(.displayMedium, color: color) }
    func vDisplaySmall(_ color: Color? = nil) -> some View { vText(.displaySmall, color: color) }
    func vHeadlineLarge(_ color: Color? = nil) -> some View { vText(.headlineLarge, color: color) }
    func vHeadlineMedium(_ color: Color? = nil) -> some View { vText(.headlineMedium, color: color) }
    func vHeadlineSmall(_ color: Color? = nil) -> some View { vText(.headlineSmall, color: color) }
    func vTitleLarge(_ color: Color? = nil) -> some View { vText(.titleLarge, color: color) }
    func vTitleMedium(_ color: Color? = nil) -> some View { vText(.titleMedium, color: color) }
    func vTitleSmall(_ color: Color? = nil) -> some View { vText(.titleSmall, color: color) }
    func vBodyLarge(_ color: Color? = nil) -> some View { vText(.bodyLarge, color: color) }
    func vBodyMedium(_ color: Color? = nil) -> some View { vText(.bodyMedium, color: color) }
    func vBodySmall(_ color: Color? = nil) -> some View { vText(.bodySmall, color: color) }
    func vLabelLarge(_ color: Color? = nil) -> some View { vText(.labelLarge, color: color) }
    func vLabelMedium(_ color: Color? = nil) -> some View { vText(.labelMedium, color: color) }
    func vLabelSmall(_ color: Color? = nil) -> some View { vText(.labelSmall, color: color) }

    /// Muted secondary line: bodySmall, `Theme.textMuted` (Windows `Text.Muted`).
    func vMuted() -> some View { vText(.bodySmall, color: Theme.textMuted) }

    /// One line, ellipsized, titleSmall (Windows `Text.OneLine`; card titles).
    func vOneLine() -> some View { vText(.titleSmall).lineLimit(1).truncationMode(.tail) }
}
