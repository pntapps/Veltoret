import SwiftUI
import VeltoretKit
import VeltoretPlayerKit
import VeltoretUI

/// The right-side panel (Audio, Subtitles, Speed, Episodes, More, Sleep timer, Video info) over a dim scrim.
struct PanelLayer: View {
    @ObservedObject var controller: PlayerController
    let content: PanelContent
    let width: CGFloat

    var body: some View {
        let c = controller
        HStack(spacing: 0) {
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture { c.closePanel() }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if content.showsBack {
                        Button { c.panelBack() } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(PlayerRoundStyle(size: 36)).help("Back")
                    }
                    Text(content.title).font(Theme.serif(20)).lineLimit(1)
                    Spacer(minLength: 8)
                    Button { c.closePanel() } label: { Image(systemName: "xmark") }
                        .buttonStyle(PlayerRoundStyle(size: 36)).help("Close")
                }
                .padding(.leading, content.showsBack ? 12 : 20).padding(.trailing, 12)
                .padding(.top, 18).padding(.bottom, 8)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(content.rows) { row in
                                PanelRowView(controller: c, row: row).id(row.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 16)
                    }
                    .onAppear { scroll(proxy) }
                    .onChange(of: content.scrollTo) { scroll(proxy) }
                }
            }
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.surface)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.outline).frame(width: 1) }
            .onHover { _ in c.bumpInteraction() }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = content.scrollTo else { return }
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
    }
}

private struct PanelRowView: View {
    @ObservedObject var controller: PlayerController
    let row: PanelRow

    var body: some View {
        switch row {
        case .row(_, let title, let detail, let icon, let check, let enabled, let action):
            Button(action: action) {
                HStack(spacing: 0) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Theme.textMuted)
                            .frame(width: 22).padding(.trailing, 16)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if let detail, !detail.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(detail).font(Theme.sans(12.5)).foregroundStyle(Theme.textMuted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                    if check {
                        Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.amber)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelRowStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)

        case .note(_, let text, let danger):
            Text(text).font(Theme.sans(13)).foregroundStyle(danger ? Theme.danger : Theme.textMuted)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)

        case .header(_, let text):
            Text(text).font(Theme.sans(11, .bold)).foregroundStyle(Theme.amber)
                .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 6)

        case .busy:
            HStack { Spacer(); VSpinner(size: 28, lineWidth: 3, color: Theme.amber); Spacer() }.padding(.vertical, 16)

        case .divider:
            Rectangle().fill(Theme.outline).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 8)

        case .sync(_, let label):
            SyncControl(controller: controller, label: label)

        case .info(_, let key, let value):
            HStack(alignment: .top, spacing: 0) {
                Text(key).font(Theme.sans(13)).foregroundStyle(Theme.textMuted).frame(width: 120, alignment: .leading)
                Text(value).font(Theme.sans(13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)

        case .softwareToggle(_, let on):
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Software video decoding").font(Theme.sans(15, .semibold))
                    Text("Turns off hardware acceleration. Try it if the picture is green, frozen or glitchy. Uses more power; 4K may stutter.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { on }, set: { controller.setSoftwareDecoding($0) }))
                    .labelsHidden()
                    .toggleStyle(.vSwitch)
            }
            .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 8)

        case .episode(let item):
            EpisodeRow(controller: controller, item: item)
        }
    }
}

private struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? Theme.pressed : hover ? Theme.hover : Color.clear))
                .onHover { hover = $0 }
        }
    }
}

private struct SyncControl: View {
    @ObservedObject var controller: PlayerController
    let label: String

    var body: some View {
        let c = controller
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sync").font(Theme.sans(14, .semibold))
                Spacer()
                Text(label).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.amber)
            }
            HStack(spacing: 6) {
                ForEach([("−1 s", Int64(-1000)), ("−0.1 s", -100), ("Reset", 0), ("+0.1 s", 100), ("+1 s", 1000)], id: \.0) { item in
                    Button {
                        c.setSubtitleOffset(item.1 == 0 ? 0 : c.subtitleOffsetMs + item.1)
                        c.refreshPanel()
                    } label: { Text(item.0).lineLimit(1) }
                        .buttonStyle(PlayerChipStyle(kind: .outline, height: 34))
                }
            }
            .padding(.top, 10)
            Text("Use + if subtitles appear before the speech, − if they're late.")
                .font(Theme.sans(12.5)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }
}

private struct EpisodeRow: View {
    @ObservedObject var controller: PlayerController
    let item: EpisodeRowItem

    var body: some View {
        Button { controller.playEpisodeRow(item) } label: {
            HStack(spacing: 0) {
                ArtworkImage(url: item.stillUrl, fallbackText: "E\(item.episode)", cornerRadius: 10, maxPixel: 320)
                    .frame(width: 120, height: 67.5)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(PlayerFormat.episodeCode(item.season, item.episode))
                        .font(Theme.sans(12, .semibold)).foregroundStyle(item.isCurrent ? Theme.amber : Theme.textMuted)
                    Text(item.name).font(Theme.sans(14.5, .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if item.isCurrent {
                        Text("Now playing").font(Theme.sans(12)).foregroundStyle(Theme.amberSoft).padding(.top, 1)
                    }
                }
                .padding(.leading, 14).padding(.trailing, 8)
                Spacer(minLength: 0)
                if item.watched {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.amber)
                        .accessibilityLabel("Watched")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(item.isCurrent ? Theme.amberDim : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowStyle())
        .disabled(item.isCurrent)
        .padding(.bottom, 4)
    }
}
