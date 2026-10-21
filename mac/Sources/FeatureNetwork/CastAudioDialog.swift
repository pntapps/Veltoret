import SwiftUI
import VeltoretCast
import VeltoretKit
import VeltoretUI

/// "Audio on the TV": asked before casting a video with several audio tracks, since a Chromecast plays only the one
/// it's given. The current track is marked; "Keep current" (or Esc) keeps it.
@MainActor
public enum CastAudioDialog {
    /// The chosen MKV track number, or nil to keep the current one.
    public static func ask(deviceName: String?, options: [CastAudioOption], current: Int64?) async -> Int64? {
        await Dialogs.present { (ctl: DialogController<Int64>) in
            VDialog(title: "Audio on \(deviceName ?? "the TV")") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options, id: \.track) { option in
                        let selected = option.track == current
                        Button { ctl.close(option.track) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).vTitleMedium(selected ? Theme.amber : Theme.text).lineLimit(1)
                                    if !option.detail.trimmingCharacters(in: .whitespaces).isEmpty {
                                        Text(option.detail).vBodySmall(Theme.textMuted).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                if selected { Text("Current").vLabelMedium(Theme.amber) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(VRowButtonStyle(padding: EdgeInsets(top: 12, leading: 6, bottom: 12, trailing: 6)))
                    }
                    Text("You can switch later from the casting panel.").vBodySmall(Theme.textMuted)
                        .padding(EdgeInsets(top: 8, leading: 6, bottom: 0, trailing: 0))
                }
                .frame(minWidth: 340)
            } actions: {
                Button("Keep current") { ctl.dismiss() }.buttonStyle(.vTextMuted).keyboardShortcut(.cancelAction)
            }
        }
    }
}
