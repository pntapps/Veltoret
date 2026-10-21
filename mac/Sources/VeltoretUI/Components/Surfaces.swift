import AppKit
import SwiftUI
import VeltoretKit

// MARK: - Cards / panels

public extension View {
    /// Card / Panel (Windows `Card`): Surface fill, 1 pt Outline hairline, corner 14, padding 16.
    func vPanel(padding: CGFloat = 16, fill: Color = Theme.surface, radius: CGFloat = Theme.Radius.card) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .vHairline(radius)
    }

    /// Same as `vPanel` but sized to its content (doesn't fill the width).
    func vCard(padding: CGFloat = 16, fill: Color = Theme.surface, radius: CGFloat = Theme.Radius.card) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .vHairline(radius)
    }
}

/// A panel that reacts like a button (corner 14, OutlineStrong border on hover, press 0.98).
public struct VClickPanel<Content: View>: View {
    let padding: CGFloat
    let action: () -> Void
    let content: Content
    @State private var hovering = false

    public init(padding: CGFloat = 16, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.padding = padding; self.action = action; self.content = content()
    }

    public var body: some View {
        Button(action: action) {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
                .vHairline(Theme.Radius.card, color: hovering ? Theme.outlineStrong : Theme.outline)
        }
        .buttonStyle(VPlainButtonStyle(pressScale: 0.98))
        .onHover { hovering = $0 }
    }
}

/// 1 pt Outline divider (horizontal by default).
public struct VDivider: View {
    let vertical: Bool
    public init(vertical: Bool = false) { self.vertical = vertical }
    public var body: some View {
        Rectangle().fill(Theme.outline).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

// MARK: - Pills

/// Pill (badge): uppercased labelSmall, corner 6, padding 7×3, 1 pt border.
public struct VPill: View {
    public enum Style: Sendable {
        /// Transparent, Text label, OutlineStrong border.
        case plain
        /// 85 % background fill (on images), Text label, OutlineStrong border.
        case solid
        /// AmberDim fill, AmberSoft label, Amber 50 % border.
        case accent
    }

    let text: String
    let style: Style

    public init(_ text: String, style: Style = .plain) { self.text = text; self.style = style }

    /// A quality badge ("4K", "HDR", "Dolby Vision", "1080p", "REMUX"…): accent for 4K / HDR / Dolby Vision, else plain.
    public static func quality(_ label: String, onImage: Bool = false) -> VPill {
        let l = label.lowercased()
        let premium = l.contains("4k") || l.contains("2160") || l.contains("hdr") || l.contains("dolby") || l == "dv"
        return VPill(label, style: premium ? .accent : onImage ? .solid : .plain)
    }

    public var body: some View {
        Text(text.uppercased())
            .vLabelSmall(style == .accent ? Theme.amberSoft : Theme.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                .fill(style == .accent ? Theme.amberDim : style == .solid ? Theme.pillSolid : .clear))
            .vHairline(Theme.Radius.pill, color: style == .accent ? Theme.amberHalf : Theme.outlineStrong)
    }
}

/// Rating: 15 pt Amber star, 3 gap, "7.8" labelLarge. Renders nothing when `rating <= 0`.
public struct VRating: View {
    let rating: Double
    public init(_ rating: Double) { self.rating = rating }
    public var body: some View {
        if rating > 0 {
            HStack(spacing: 3) {
                Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(Theme.amber)
                Text(Formats.rating(rating)).vLabelLarge()
            }
        }
    }
}

/// MetaLine: drops blank parts, joins with "  ·  ", bodyMedium TextMuted, max 2 lines.
public struct VMetaLine: View {
    let parts: [String?]
    public init(_ parts: String?...) { self.parts = parts }
    public init(parts: [String?]) { self.parts = parts }
    public var body: some View { Text(Formats.join(parts)).vBodyMedium(Theme.textMuted).lineLimit(2) }
}

// MARK: - Headers

/// SectionHeader: headlineSmall title (fills) + optional amber text action ("See all"); gutter padding.
public struct VSectionHeader: View {
    let title: String
    let actionTitle: String?
    let action: (() -> Void)?
    let gutter: CGFloat

    public init(_ title: String, actionTitle: String? = nil, gutter: CGFloat = Theme.gutter, action: (() -> Void)? = nil) {
        self.title = title; self.actionTitle = actionTitle; self.action = action; self.gutter = gutter
    }

    public var body: some View {
        HStack(alignment: .center) {
            Text(title).vHeadlineSmall().lineLimit(1)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.vText)
            }
        }
        .padding(.leading, gutter)
        .padding(.trailing, max(0, gutter - 8))
    }
}

/// ScreenHeader: optional round Back button (+12 gap), headlineLarge title, bodySmall muted subtitle, actions on the
/// right (8 spacing). Padding: leading 12 with Back else gutter, trailing 12, top 12, bottom 8.
/// `showsBack: true` calls `Navigator.shared.goBack()`.
public struct VScreenHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    let showsBack: Bool
    let actions: Actions

    public init(_ title: String, subtitle: String? = nil, showsBack: Bool = false, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.subtitle = subtitle; self.showsBack = showsBack; self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: 0) {
            if showsBack {
                VIconButton("chevron.left", help: "Back") { Navigator.shared.goBack() }
                    .padding(.trailing, 12)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).vHeadlineLarge().lineLimit(1)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).vBodySmall(Theme.textMuted).lineLimit(1) }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions }
        }
        .padding(.leading, showsBack ? 12 : Theme.gutter)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

public extension VScreenHeader where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil, showsBack: Bool = false) {
        self.init(title, subtitle: subtitle, showsBack: showsBack) { EmptyView() }
    }
}

// MARK: - States

/// EmptyState: 72 pt Surface disc (Outline hairline) with a 32 pt Amber SF Symbol, headlineSmall title, bodyMedium muted
/// message, optional primary action. Centered, max width 520, padding 32.
public struct VEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(icon: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon; self.title = title; self.message = message; self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Theme.surface)
                Circle().strokeBorder(Theme.outline, lineWidth: 1)
                Image(systemName: icon).font(.system(size: 28, weight: .regular)).foregroundStyle(Theme.amber)
            }
            .frame(width: 72, height: 72)
            Text(title).vHeadlineSmall().multilineTextAlignment(.center).padding(.top, 20)
            Text(message).vBodyMedium(Theme.textMuted).multilineTextAlignment(.center).padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                VButton(actionTitle, kind: .primary, action: action).padding(.top, 24)
            }
        }
        .frame(maxWidth: 520)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// LoadingBox: a centered 32 pt Amber spinner (stroke 2.5), min height 120 (or a fixed `height`).
public struct VLoadingBox: View {
    let height: CGFloat?
    public init(height: CGFloat? = nil) { self.height = height }
    public var body: some View {
        VSpinner(size: 32, lineWidth: 2.5)
            .frame(maxWidth: .infinity, minHeight: height ?? 120, maxHeight: height ?? .infinity)
    }
}

// MARK: - Brand

/// "Veltoret" + an amber dot near the baseline, like a period. headlineMedium (large: displayMedium).
public struct Wordmark: View {
    let large: Bool
    public init(large: Bool = false) { self.large = large }
    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 3) {
            Text("Veltoret").vText(large ? .displayMedium : .headlineMedium).lineLimit(1).fixedSize()
            Circle().fill(Theme.amber).frame(width: large ? 9 : 6, height: large ? 9 : 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Veltoret")
    }
}

/// The rail logo: "V" in displaySmall + a 6 pt amber dot at its baseline.
public struct RailLogo: View {
    public init() {}
    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text("V").vDisplaySmall()
            Circle().fill(Theme.amber).frame(width: 6, height: 6)
        }
        .accessibilityLabel("Veltoret")
    }
}

/// The app logo image (`Resources/Images/logo.png`, 256 px). Falls back to `RailLogo` if the resource is missing.
public struct AppLogo: View {
    let size: CGFloat
    public init(size: CGFloat = 64) { self.size = size }

    /// The logo as an NSImage (nil when the resource isn't bundled).
    public static let image: NSImage? = {
        let url = Bundle.module.url(forResource: "logo", withExtension: "png", subdirectory: "Images")
            ?? Bundle.module.url(forResource: "logo", withExtension: "png")
        return url.flatMap { NSImage(contentsOf: $0) }
    }()

    public var body: some View {
        if let img = AppLogo.image {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RailLogo().frame(width: size, height: size)
        }
    }
}

/// TMDB attribution (required by TMDB's terms): their logo (height 12) then 8 gap and the notice in bodySmall TextFaint.
/// Used by onboarding and Settings → About.
public struct TmdbAttribution: View {
    /// The exact notice TMDB requires.
    public static let notice = "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TmdbLogo(height: 12)
            Text(Self.notice).vBodySmall(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// TMDB's wordmark logo (aspect 273.42 : 35.52): "TMDB" lettering beside a rounded bar, in TMDB's own gradient
/// (#90CEA1 → #3CBEC9 → #01B4E4) — the one allowed exception to the no-gradient rule.
public struct TmdbLogo: View {
    let height: CGFloat
    public init(height: CGFloat = 12) { self.height = height }
    public var body: some View {
        let gradient = LinearGradient(stops: [
            .init(color: Color(hex: 0xFF90CEA1), location: 0),
            .init(color: Color(hex: 0xFF3CBEC9), location: 0.56),
            .init(color: Color(hex: 0xFF01B4E4), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
        HStack(spacing: height * 0.4) {
            Text("TMDB").font(.system(size: height * 1.08, weight: .black)).fixedSize()
            Capsule().frame(height: height * 0.72)
        }
        .frame(width: height * 273.42 / 35.52, height: height, alignment: .leading)
        .foregroundStyle(gradient)
        .help("The Movie Database (TMDB)")
        .accessibilityLabel("The Movie Database (TMDB)")
    }
}

/// The scan chip (Home header / rail slot): 12 pt spinner + labelMedium muted text, corner 10, Surface, hairline.
public struct VScanChip: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        HStack(spacing: 8) {
            VSpinner(size: 12, lineWidth: 1.5)
            Text(text).vLabelMedium(Theme.textMuted).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.surface))
        .vHairline(Theme.Radius.chip)
    }
}

/// Opens a URL in the default browser (toast on failure).
@MainActor
public func openInBrowser(_ string: String) {
    guard let url = URL(string: string), NSWorkspace.shared.open(url) else {
        Toast.show("Couldn't open the browser")
        return
    }
}
