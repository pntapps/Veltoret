import AppKit
import SwiftUI
import VeltoretKit
import VeltoretUI

// Settings building blocks (Android: SettingRow, SwitchRow, ChoiceRow, group titles, panels; Windows SettingsRows).

/// Group title: UPPERCASE, amber, small label (padding start 8, top 28, bottom 10).
public struct SettingsGroupTitle: View {
    let title: String
    public init(_ title: String) { self.title = title }
    public var body: some View {
        Text(title.uppercased(with: Locale(identifier: "en_US")))
            .vLabelMedium(Theme.amber)
            .padding(.leading, 8)
            .padding(.top, 28)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A panel (Surface, hairline, corner 14) whose rows are given as a stack; put `SettingsDivider()` between rows.
public struct SettingsPanel<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surface))
            .vHairline(Theme.Radius.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// 1 pt divider inset 16 on both sides.
public struct SettingsDivider: View {
    public init() {}
    public var body: some View { VDivider().padding(.horizontal, 16) }
}

/// Title, optional subtitle and amber icon, and a chevron when clickable.
public struct SettingRow: View {
    let title: String
    let subtitle: String?
    let icon: String?
    let chevron: Bool
    let subtitleColor: Color
    let action: (() -> Void)?

    public init(_ title: String, subtitle: String? = nil, icon: String? = nil, chevron: Bool = true,
                subtitleColor: Color = Theme.textMuted, action: (() -> Void)? = nil) {
        self.title = title; self.subtitle = subtitle; self.icon = icon; self.chevron = chevron
        self.subtitleColor = subtitleColor; self.action = action
    }

    public var body: some View {
        let content = HStack(spacing: 16) {
            if let icon {
                Image(systemName: icon).font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.amber)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).vTitleSmall()
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).vBodySmall(subtitleColor).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if action != nil && chevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }.buttonStyle(SettingsRowButtonStyle())
        } else {
            content
        }
    }
}

/// Title, subtitle and a switch; the whole row toggles.
public struct SwitchRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    public init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title; self.subtitle = subtitle; _isOn = isOn
    }

    public var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).vTitleSmall()
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).vBodySmall(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VToggle(isOn: $isOn).allowsHitTesting(false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Title on the left, the selected label in amber on the right ("—" if none); a click opens a menu where the
/// selected item is checked.
public struct ChoiceRow<T: Hashable>: View {
    let title: String
    let options: [(T, String)]
    let selected: T
    let onSelect: (T) -> Void

    public init(_ title: String, options: [(T, String)], selected: T, onSelect: @escaping (T) -> Void) {
        self.title = title; self.options = options; self.selected = selected; self.onSelect = onSelect
    }

    private var label: String { options.first { $0.0 == selected }?.1 ?? "—" }

    public var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Button {
                    onSelect(o.0)
                } label: {
                    if o.0 == selected { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(title).vTitleSmall().frame(maxWidth: .infinity, alignment: .leading)
                Text(label).vLabelLarge(Theme.amber)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(label)
    }
}

/// Plain text inside a panel (padding 16).
public struct SettingsNote: View {
    let text: String
    let color: Color
    public init(_ text: String, color: Color = Theme.textMuted) { self.text = text; self.color = color }
    public var body: some View {
        Text(text).vBodySmall(color).fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A round avatar: an SF Symbol (This Mac) or the first letter of a Google account's name, on AmberDim.
struct SettingsAvatar: View {
    let icon: String?
    let letter: String?
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().fill(Theme.amberDim)
            if let icon {
                Image(systemName: icon).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(Theme.amber)
            } else {
                Text(letter ?? "?").vTitleMedium(Theme.amber)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Row highlight on hover / press (flat, no gradients).
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .background(configuration.isPressed ? Theme.pressed : hovering && enabled ? Theme.hover : Color.clear)
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// Opens a URL; toast "No browser to open <url>" when it can't (spec 3.8).
@MainActor
func openLink(_ url: String) {
    guard let u = URL(string: url), NSWorkspace.shared.open(u) else {
        Toast.show("No browser to open \(url)")
        return
    }
}

/// System Settings deep links.
enum SystemSettingsLinks {
    static var notifications: String {
        let id = Bundle.main.bundleIdentifier ?? "com.pntapps.veltoret"
        return "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)"
    }
    static let microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let speech = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
    static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    @MainActor
    static func open(_ link: String) {
        if let u = URL(string: link), NSWorkspace.shared.open(u) { return }
        // Older link form.
        if let u = URL(string: "x-apple.systempreferences:"), NSWorkspace.shared.open(u) { return }
        Toast.show("Couldn't open System Settings")
    }
}
