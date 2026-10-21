import SwiftUI
import VeltoretKit
import VeltoretUI

/// Settings (Android SettingsScreen, Windows SettingsPage): every section registered in `SettingsSections`, in
/// order. Two columns when the page is at least 840 pt wide — Library and the source sections other modules add
/// (Google accounts, Network servers, Play on TV…) on the left; Playback, Subtitles, Reminders & alerts,
/// Appearance, App, TMDB and About on the right — else one centered column, at most 760 wide.
public struct SettingsPage: View {
    @ObservedObject private var registry = SettingsSections.shared

    /// Sections FeatureSettings registers for the right column.
    static let rightColumn: Set<String> = ["playback", "subtitles", "notifications", "appearance", "app", "tmdb", "about"]

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let two = width >= 840
            let gutter: CGFloat = width >= 840 ? 40 : width >= 600 ? 28 : 20
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings").vDisplaySmall().padding(.leading, 8)
                    if two {
                        HStack(alignment: .top, spacing: 28) {
                            column(left).frame(maxWidth: .infinity, alignment: .top)
                            column(right).frame(maxWidth: .infinity, alignment: .top)
                        }
                        .frame(maxWidth: 1400)
                    } else {
                        column(left + right).frame(maxWidth: 760)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, gutter - 8)
                .padding(.top, 28)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .vPageBackground()
    }

    private var left: [SettingsSection] { registry.sections.filter { !Self.rightColumn.contains($0.id) } }
    private var right: [SettingsSection] { registry.sections.filter { Self.rightColumn.contains($0.id) } }

    private func column(_ sections: [SettingsSection]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    SettingsGroupTitle(section.title)
                    section.content()
                }
                .id(section.id)
            }
        }
    }
}
