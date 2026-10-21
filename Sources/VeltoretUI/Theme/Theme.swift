import AppKit
import SwiftUI
import VeltoretKit

/// Veltoret design tokens (Android `ui/theme/Color.kt`, Windows `Themes/Tokens.xaml`). Dark only.
///
/// Depth comes from layered flat surfaces and 1 px hairline outlines: **never use gradients** (the only exception is
/// TMDB's own logo, drawn by `TmdbAttribution`). Page backgrounds must follow the "Pure black" setting: use the
/// `.vPageBackground()` modifier (live) or `ThemeState.shared.background` inside a view that observes `ThemeState`.
public enum Theme {
    // MARK: Colors

    /// Page background (`#0B0B0D`). Prefer `.vPageBackground()`, which follows "Pure black" live.
    public static let backgroundDefault = Color(hex: 0xFF0B0B0D)
    /// Page background when "Pure black" (`AppSettings.oledBlack`) is on.
    public static let backgroundOled = Color(hex: 0xFF000000)
    /// The current page background (follows "Pure black"). Not observable by itself: inside views use
    /// `.vPageBackground()` or observe `ThemeState.shared`.
    @MainActor public static var background: Color { ThemeState.shared.background }
    /// Nav rail, panels, unselected chips, empty-state disc, text fields.
    public static let surface = Color(hex: 0xFF15151A)
    /// Image placeholder, secondary button, icon-button disc, menus, dialogs.
    public static let surfaceHigh = Color(hex: 0xFF1E1E25)
    /// Toasts, hover arrows over rows.
    public static let surfaceHighest = Color(hex: 0xFF26262F)
    /// 1 px hairlines on cards / panels / posters, progress track, dividers.
    public static let outline = Color(hex: 0xFF2C2C35)
    /// Secondary button border, pill border, hovered outlines.
    public static let outlineStrong = Color(hex: 0xFF3B3B46)
    /// Primary text (warm off-white).
    public static let text = Color(hex: 0xFFF3EFE6)
    /// Secondary text, inactive nav.
    public static let textMuted = Color(hex: 0xFF9C9AA3)
    /// Tertiary text, disabled, attributions.
    public static let textFaint = Color(hex: 0xFF6B6973)
    /// The accent: primary button, selected nav, rating star, links, progress fill.
    public static let amber = Color(hex: 0xFFE8A33D)
    /// Text on `amberDim`, offline label.
    public static let amberSoft = Color(hex: 0xFFF3C77F)
    /// Selected nav pill / chip background, accent pill background.
    public static let amberDim = Color(hex: 0xFF3A2B14)
    /// Text and icons on amber.
    public static let onAmber = Color(hex: 0xFF1B1206)
    public static let danger = Color(hex: 0xFFFF6B5E)
    public static let success = Color(hex: 0xFF6FCF97)
    /// Flat 60 % black dim used whenever something sits on top of imagery.
    public static let imageDim = Color(hex: 0x99000000)
    /// Stronger flat dim for full-screen backdrops.
    public static let backdropDim = Color(hex: 0xB8000000)
    /// Player controls background.
    public static let playerChrome = Color(hex: 0x8C000000)

    // Extra literal colors (Controls.xaml).
    /// Solid pill background (85 % of the page background).
    public static let pillSolid = Color(hex: 0xD90B0B0D)
    public static let amberHalf = Color(hex: 0x80E8A33D)
    public static let amber60 = Color(hex: 0x99E8A33D)
    /// Hover tint laid over a surface (6 % white).
    public static let hover = Color(hex: 0x0FFFFFFF)
    /// Pressed tint laid over a surface (10 % white).
    public static let pressed = Color(hex: 0x1AFFFFFF)
    public static let danger45 = Color(hex: 0x73FF6B5E)

    // MARK: Shapes & spacing

    /// Corner radii (dp = pt).
    public enum Radius {
        public static let pill: CGFloat = 6
        public static let chip: CGFloat = 10
        public static let button: CGFloat = 12
        public static let poster: CGFloat = 12
        public static let card: CGFloat = 14
        public static let dialog: CGFloat = 20
        public static let hero: CGFloat = 20
        public static let detailBackdrop: CGFloat = 24
    }

    /// Horizontal page margin (Android Expanded gutter).
    public static let gutter: CGFloat = 40
    /// Space above each home row / section.
    public static let sectionSpacing: CGFloat = 28
    /// Space between cards in a row.
    public static let rowSpacing: CGFloat = 16
    /// Width of the left sidebar rail.
    public static let railWidth: CGFloat = 92

    // MARK: Fonts

    /// Fraunces (titles) at `size`, SemiBold, optical size 72, Soft 50 (Android's title instance).
    public static func serif(_ size: CGFloat, weight: CGFloat = 600) -> Font { Fonts.serif(size, weight: weight) }
    /// Inter at `size` and `weight` (body, labels, buttons).
    public static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { Fonts.sans(size, weight) }
}

/// Live theme state: the page background follows `AppSettings.oledBlack` ("Pure black").
@MainActor
public final class ThemeState: ObservableObject {
    public static let shared = ThemeState()

    @Published public private(set) var oledBlack = false
    private var sub: Subscription?

    private init() { attach() }

    /// The page background for the current setting.
    public var background: Color { oledBlack ? Theme.backgroundOled : Theme.backgroundDefault }
    public var nsBackground: NSColor { oledBlack ? .black : NSColor(Theme.backgroundDefault) }

    /// Subscribes to settings changes (called by `VeltoretUIModule.initialize()`; safe to call again).
    public func attach() {
        guard sub == nil, let settings = AppServices.settings else { return }
        oledBlack = settings.current.oledBlack
        sub = settings.changed.subscribe { s in
            Task { @MainActor in
                let v = s.oledBlack
                if ThemeState.shared.oledBlack != v { ThemeState.shared.oledBlack = v }
            }
        }
    }
}

/// Fills behind the view with the live page background (follows "Pure black").
private struct PageBackground: ViewModifier {
    @ObservedObject private var theme = ThemeState.shared
    func body(content: Content) -> some View {
        content.background(theme.background.ignoresSafeArea())
    }
}

public extension View {
    /// The page background (`Theme.background`, follows "Pure black" live). Use on every page's root.
    func vPageBackground() -> some View { modifier(PageBackground()) }

    /// A 1 px hairline border in `color` with the given corner radius (drawn inside the bounds).
    func vHairline(_ radius: CGFloat, color: Color = Theme.outline, width: CGFloat = 1) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(color, lineWidth: width))
    }
}

public extension Color {
    /// `Color(hex: 0xAARRGGBB)`.
    init(hex: UInt32) {
        let a = Double((hex >> 24) & 0xFF) / 255
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
