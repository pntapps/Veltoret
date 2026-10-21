import AppKit
import SwiftUI

/// The look of a `VButton` / `VButtonStyle` (Windows `Button.*` styles, Android `VButton`).
public enum VButtonKind: Sendable {
    /// Amber fill, on-amber label.
    case primary
    /// SurfaceHigh fill, OutlineStrong hairline.
    case secondary
    /// Transparent, Outline hairline.
    case ghost
    /// Danger fill, on-amber label.
    case danger
    /// Amber label only, small hit area with hover tint ("See all", dialog actions).
    case text
    /// Muted label only (dialog "Cancel").
    case textMuted
    /// Danger label only (dialog destructive action).
    case textDanger
}

/// Filled/outlined text buttons: min height 48 (`compact`: 36), corner 12, padding 20×12, labelLarge.
/// Shows a hover tint, scales to 0.97 when pressed and dims when disabled.
///
/// `Button("Play") { … }.buttonStyle(VButtonStyle(.primary))` or the shorthand `.buttonStyle(.vPrimary)`.
/// For an icon and a loading spinner use `VButton`.
public struct VButtonStyle: ButtonStyle {
    public var kind: VButtonKind
    public var compact: Bool
    public var fullWidth: Bool

    public init(_ kind: VButtonKind = .primary, compact: Bool = false, fullWidth: Bool = false) {
        self.kind = kind; self.compact = compact; self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        VButtonBody(kind: kind, compact: compact, fullWidth: fullWidth, pressed: configuration.isPressed) {
            configuration.label
        }
    }
}

public extension ButtonStyle where Self == VButtonStyle {
    static var vPrimary: VButtonStyle { VButtonStyle(.primary) }
    static var vSecondary: VButtonStyle { VButtonStyle(.secondary) }
    static var vGhost: VButtonStyle { VButtonStyle(.ghost) }
    static var vDanger: VButtonStyle { VButtonStyle(.danger) }
    static var vText: VButtonStyle { VButtonStyle(.text) }
    static var vTextMuted: VButtonStyle { VButtonStyle(.textMuted) }
}

struct VButtonBody<Label: View>: View {
    let kind: VButtonKind
    let compact: Bool
    let fullWidth: Bool
    let pressed: Bool
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    private var isTextKind: Bool { kind == .text || kind == .textMuted || kind == .textDanger }

    private var fill: Color {
        if !enabled && !isTextKind { return Theme.surfaceHigh }
        switch kind {
        case .primary: return Theme.amber
        case .secondary: return Theme.surfaceHigh
        case .danger: return Theme.danger
        default: return .clear
        }
    }

    private var border: Color {
        if !enabled && !isTextKind { return Theme.outline }
        switch kind {
        case .primary: return Theme.amber
        case .secondary: return Theme.outlineStrong
        case .ghost: return Theme.outline
        case .danger: return Theme.danger
        default: return .clear
        }
    }

    private var foreground: Color {
        if !enabled { return Theme.textFaint }
        switch kind {
        case .primary, .danger: return Theme.onAmber
        case .secondary, .ghost: return Theme.text
        case .text: return Theme.amber
        case .textMuted: return Theme.textMuted
        case .textDanger: return Theme.danger
        }
    }

    var body: some View {
        let radius: CGFloat = isTextKind ? 8 : Theme.Radius.button
        label()
            .vText(.labelLarge, color: foreground)
            .lineLimit(1)
            .padding(.horizontal, isTextKind ? 8 : (compact ? 14 : 20))
            .padding(.vertical, isTextKind ? 6 : (compact ? 8 : 12))
            .frame(minHeight: isTextKind ? nil : (compact ? 36 : 48))
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(pressed && isTextKind ? Theme.pressed : (hovering && enabled ? Theme.hover : .clear)))
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(border, lineWidth: isTextKind ? 0 : 1))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .vPressScale(pressed && !isTextKind, 0.97)
            .onHover { hovering = $0 }
    }
}

/// A text button with an optional SF Symbol icon (20 pt, 8 gap) and a loading state (18 pt spinner, click disabled).
///
/// `VButton("Scan now", icon: "arrow.clockwise", kind: .primary, loading: scanning) { … }`
public struct VButton: View {
    let title: String
    let icon: String?
    let kind: VButtonKind
    let loading: Bool
    let compact: Bool
    let fullWidth: Bool
    let action: () -> Void

    public init(_ title: String, icon: String? = nil, kind: VButtonKind = .primary, loading: Bool = false,
                compact: Bool = false, fullWidth: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.kind = kind; self.loading = loading
        self.compact = compact; self.fullWidth = fullWidth; self.action = action
    }

    public var body: some View {
        Button(action: { if !loading { action() } }) {
            HStack(spacing: 0) {
                if loading {
                    VSpinner(size: kind == .text || kind == .textMuted ? 16 : 18, lineWidth: 2, color: nil)
                        .padding(.trailing, 10)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: kind == .text ? 15 : 16, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .padding(.trailing, title.isEmpty ? 0 : 8)
                }
                if !title.isEmpty { Text(title) }
            }
        }
        .buttonStyle(VButtonStyle(kind, compact: compact, fullWidth: fullWidth))
        .allowsHitTesting(!loading)
    }
}

/// The look of a round icon button.
public enum VIconButtonKind: Sendable {
    /// SurfaceHigh disc with an Outline hairline (default).
    case standard
    /// 60 % black disc, no border, for buttons on top of imagery.
    case onImage
    /// No disc, muted icon (small "×" in lists, trailing icons).
    case flat
}

/// Round icon button (`VIconButton`): 42 pt circle by default, icon at 50 % of the size, hover tint, press 0.94,
/// tooltip = `help` (also the accessibility label).
///
/// `VIconButton("magnifyingglass", help: "Search") { nav.push(.search()) }`
public struct VIconButton: View {
    let systemName: String
    let help: String
    let size: CGFloat
    let kind: VIconButtonKind
    let tint: Color?
    let action: () -> Void

    public init(_ systemName: String, help: String, size: CGFloat = 42, kind: VIconButtonKind = .standard,
                tint: Color? = nil, action: @escaping () -> Void) {
        self.systemName = systemName; self.help = help; self.size = size; self.kind = kind; self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: kind == .flat ? min(16, size / 2) : size * 0.42, weight: .medium))
                .foregroundStyle(tint ?? (kind == .flat ? Theme.textMuted : Theme.text))
        }
        .buttonStyle(VIconButtonStyle(size: size, kind: kind))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The ButtonStyle behind `VIconButton`, usable with any label (e.g. a custom glyph).
public struct VIconButtonStyle: ButtonStyle {
    public var size: CGFloat
    public var kind: VIconButtonKind
    public init(size: CGFloat = 42, kind: VIconButtonKind = .standard) { self.size = size; self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(size: kind == .flat && size == 42 ? 32 : size, kind: kind, pressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct IconButtonBody<Label: View>: View {
    let size: CGFloat
    let kind: VIconButtonKind
    let pressed: Bool
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle().fill(kind == .standard ? Theme.surfaceHigh : kind == .onImage ? Theme.imageDim : .clear)
            if kind == .standard { Circle().strokeBorder(Theme.outline, lineWidth: 1) }
            if hovering && enabled { Circle().fill(Theme.hover) }
            label()
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .opacity(enabled ? 1 : 0.45)
        .vPressScale(pressed, 0.94)
        .onHover { hovering = $0 }
    }
}

/// No chrome: a clickable area whose content decides the look (cards). Optional press scale and hover callback.
public struct VPlainButtonStyle: ButtonStyle {
    public var pressScale: CGFloat
    public init(pressScale: CGFloat = 1) { self.pressScale = pressScale }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .vPressScale(configuration.isPressed && pressScale < 1, pressScale)
    }
}

/// Clickable row with a corner-14 hover highlight (episode rows, choice rows, folder rows). Padding 12×8.
public struct VRowButtonStyle: ButtonStyle {
    public var selected: Bool
    public var padding: EdgeInsets
    public init(selected: Bool = false, padding: EdgeInsets = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)) {
        self.selected = selected; self.padding = padding
    }
    public func makeBody(configuration: Configuration) -> some View {
        RowBody(selected: selected, padding: padding, pressed: configuration.isPressed) { configuration.label }
    }
}

private struct RowBody<Label: View>: View {
    let selected: Bool
    let padding: EdgeInsets
    let pressed: Bool
    @ViewBuilder let label: () -> Label
    @State private var hovering = false
    var body: some View {
        label()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(selected ? Theme.amberDim : pressed ? Theme.pressed : hovering ? Theme.hover : .clear))
            .foregroundStyle(selected ? Theme.amberSoft : Theme.text)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .onHover { hovering = $0 }
    }
}
