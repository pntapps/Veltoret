import SwiftUI

/// Select chip (Android `SelectChip`, Windows `Chip`): height 36, corner 10, padding 14, labelLarge.
/// Selected: AmberDim fill, Amber 60 % border, AmberSoft label. Optional 16 pt SF Symbol + 6 gap.
///
/// `VChip("Action", selected: genre == "Action") { genre = "Action" }`
public struct VChip: View {
    let title: String
    let icon: String?
    let selected: Bool
    let action: () -> Void

    public init(_ title: String, icon: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.selected = selected; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Theme.amberSoft : Theme.textMuted)
                }
                Text(title).vLabelLarge(selected ? Theme.amberSoft : Theme.text).lineLimit(1)
            }
        }
        .buttonStyle(ChipStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(selected: selected, pressed: configuration.isPressed) { configuration.label }
    }
}

private struct ChipBody<Label: View>: View {
    let selected: Bool
    let pressed: Bool
    @ViewBuilder let label: () -> Label
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        label()
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(selected ? Theme.amberDim : hovering ? Theme.surfaceHigh : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(selected ? Theme.amber60 : Theme.outline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
            .vPressScale(pressed, 0.97)
            .onHover { hovering = $0 }
    }
}

/// Material-style switch (52×32 track). On: Amber track, 24 pt OnAmber thumb; off: SurfaceHigh track with an
/// OutlineStrong 2 pt border, 16 pt TextMuted thumb.
///
/// `VToggle(isOn: $on)` or with a label: `VToggle("Pure black", subtitle: "True black background…", isOn: $oled)`
/// (label row fills the width, the switch sits on the right; clicking the row toggles).
public struct VToggle: View {
    let title: String?
    let subtitle: String?
    @Binding var isOn: Bool

    public init(isOn: Binding<Bool>) { title = nil; subtitle = nil; _isOn = isOn }
    public init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title; self.subtitle = subtitle; _isOn = isOn
    }

    public var body: some View {
        if let title {
            Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).vBodyLarge()
                        if let subtitle, !subtitle.isEmpty { Text(subtitle).vBodySmall(Theme.textMuted) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VSwitchTrack(isOn: isOn)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOn ? "On" : "Off")
        } else {
            Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: { VSwitchTrack(isOn: isOn) }
                .buttonStyle(.plain)
                .accessibilityValue(isOn ? "On" : "Off")
        }
    }
}

struct VSwitchTrack: View {
    let isOn: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(isOn ? Theme.amber : Theme.surfaceHigh)
            Capsule().strokeBorder(isOn ? Theme.amber : Theme.outlineStrong, lineWidth: 2)
            Circle().fill(isOn ? Theme.onAmber : Theme.textMuted)
                .frame(width: isOn ? 24 : 16, height: isOn ? 24 : 16)
                .padding(.leading, isOn ? 24 : 8)
        }
        .frame(width: 52, height: 32)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// A `ToggleStyle` with the Veltoret switch, for `Toggle("…", isOn:)`.
public struct VSwitchToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label.vBodyLarge().frame(maxWidth: .infinity, alignment: .leading)
            VSwitchTrack(isOn: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() } }
    }
}

/// A `ToggleStyle` for checkboxes: 20 pt box, corner 5, 2 pt OutlineStrong border; checked = Amber with an OnAmber check.
public struct VCheckboxToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        CheckboxBody(configuration: configuration)
    }
}

private struct CheckboxBody: View {
    let configuration: ToggleStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isOn ? Theme.amber : .clear)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(configuration.isOn || hovering ? Theme.amber : Theme.outlineStrong, lineWidth: 2)
                if configuration.isOn {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onAmber)
                }
            }
            .frame(width: 20, height: 20)
            configuration.label.vBodyMedium()
        }
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .onTapGesture { configuration.isOn.toggle() }
    }
}

public extension ToggleStyle where Self == VSwitchToggleStyle { static var vSwitch: VSwitchToggleStyle { VSwitchToggleStyle() } }
public extension ToggleStyle where Self == VCheckboxToggleStyle { static var vCheckbox: VCheckboxToggleStyle { VCheckboxToggleStyle() } }

/// Outlined text field (Android `VTextField`, Windows `TextBox`): min height 52, corner 12, Surface fill, Outline
/// border (OutlineStrong on hover, Amber when focused), 16 pt Inter, TextFaint placeholder, optional leading SF Symbol
/// and trailing content (e.g. a clear button).
///
/// `VTextField("Search", text: $q, icon: "magnifyingglass", onSubmit: run)`;
/// `VTextField("Password", text: $pw, secure: true)`.
public struct VTextField<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    let icon: String?
    let secure: Bool
    let onSubmit: (() -> Void)?
    let trailing: Trailing
    @FocusState private var focused: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    public init(_ placeholder: String, text: Binding<String>, icon: String? = nil, secure: Bool = false,
                onSubmit: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.placeholder = placeholder; _text = text; self.icon = icon; self.secure = secure
        self.onSubmit = onSubmit; self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(focused ? Theme.amber : Theme.textMuted)
                    .frame(width: 20)
            }
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder).font(Fonts.sans(16)).foregroundStyle(Theme.textFaint).lineLimit(1)
                        .padding(.leading, 1).allowsHitTesting(false)
                }
                Group {
                    if secure { SecureField("", text: $text) } else { TextField("", text: $text) }
                }
                .textFieldStyle(.plain)
                .font(Fonts.sans(16))
                .foregroundStyle(Theme.text)
                .tint(Theme.amber)
                .focused($focused)
                .onSubmit { onSubmit?() }
            }
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
            .strokeBorder(focused ? Theme.amber : hovering ? Theme.outlineStrong : Theme.outline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onHover { hovering = $0 }
        .opacity(enabled ? 1 : 0.5)
    }
}

public extension VTextField where Trailing == EmptyView {
    init(_ placeholder: String, text: Binding<String>, icon: String? = nil, secure: Bool = false,
         onSubmit: (() -> Void)? = nil) {
        self.init(placeholder, text: text, icon: icon, secure: secure, onSubmit: onSubmit) { EmptyView() }
    }
}

/// Secure variant of `VTextField` (password, API keys).
public struct VSecureField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String?
    let onSubmit: (() -> Void)?
    public init(_ placeholder: String, text: Binding<String>, icon: String? = "lock", onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder; _text = text; self.icon = icon; self.onSubmit = onSubmit
    }
    public var body: some View { VTextField(placeholder, text: $text, icon: icon, secure: true, onSubmit: onSubmit) }
}

/// Thin progress bar (Android `VProgress`): full width, 3 pt by default, rounded, Amber fill on `track`
/// (Outline; use `Theme.imageDim` over images). `value` is clamped to 0…1.
public struct VProgressBar: View {
    let value: Double
    let height: CGFloat
    let track: Color
    let fill: Color
    public init(_ value: Double, height: CGFloat = 3, track: Color = Theme.outline, fill: Color = Theme.amber) {
        self.value = value; self.height = height; self.track = track; self.fill = fill
    }
    public var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: g.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
    }
}

/// Indeterminate circular spinner: a rotating 270° arc with round caps (1 turn per second).
/// `color: nil` uses the current foreground style.
public struct VSpinner: View {
    let size: CGFloat
    let lineWidth: CGFloat
    let color: Color?
    @State private var spinning = false
    public init(size: CGFloat = 18, lineWidth: CGFloat = 2, color: Color? = Theme.amber) {
        self.size = size; self.lineWidth = lineWidth; self.color = color
    }
    public var body: some View {
        Group {
            if let color {
                Circle().trim(from: 0, to: 0.75).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            } else {
                Circle().trim(from: 0, to: 0.75).stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .frame(width: size - lineWidth, height: size - lineWidth)
        .rotationEffect(.degrees(spinning ? 360 : 0))
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spinning = true }
        }
        .accessibilityLabel("Loading")
    }
}
