import SwiftUI
import VeltoretDrive
import VeltoretKit
import VeltoretUI

/// An upload or extraction (Android/Windows `TransferCard`): icon, title, status ("Failed" / "Done" / "Waiting" /
/// "{percent}%"), an optional detail line and a progress bar while it runs. Failed cards have a danger border.
/// Mac: hover shows Cancel (running), Retry and Dismiss (finished / failed) buttons.
struct TransferCard: View {
    let job: TransferJob
    var title: String?
    /// Files panel: Retry / Cancel / Dismiss buttons. Archives page: none (it has its own "Try again").
    var actions = true
    @State private var hovering = false

    private var failed: Bool { job.state == .failed }
    private var done: Bool { job.state == .succeeded }
    private var waiting: Bool { job.state == .enqueued || job.state == .waiting }
    private var percent: Int { Int((min(1, max(0, Double(job.progress))) * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: failed ? "exclamationmark.circle.fill" : done ? "checkmark.circle.fill"
                      : job.kind == .upload ? "icloud.and.arrow.up" : "archivebox")
                    .font(.system(size: 16))
                    .foregroundStyle(failed ? Theme.danger : done ? Theme.success : Theme.amber)
                    .frame(width: 20)
                Text(title ?? job.name).vTitleSmall().lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if actions && (hovering || failed) {
                    buttons
                } else {
                    Text(failed ? "Failed" : done ? "Done" : waiting ? "Waiting" : "\(percent)%")
                        .vLabelMedium(failed ? Theme.danger : Theme.textMuted)
                        .lineLimit(1)
                }
            }
            if let detail = Self.detail(job), !detail.isEmpty {
                Text(detail).vBodySmall(failed ? Theme.danger : Theme.textMuted)
                    .lineLimit(2)
                    .padding(.leading, 30)
                    .padding(.top, 4)
                    .help(detail)
            }
            if !job.isFinished {
                Group {
                    if waiting || (job.state == .running && job.progress <= 0) {
                        IndeterminateBar()
                    } else {
                        VProgressBar(Double(job.progress), height: 3)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.surfaceHigh))
        .vHairline(Theme.Radius.card, color: failed ? Theme.danger45 : Theme.outline)
        .onHover { hovering = $0 }
        .contextMenu {
            if actions {
                if job.state == .failed { Button("Retry") { AppServices.transfers.retry(job.id) } }
                if job.isActive { Button("Cancel") { AppServices.transfers.cancel(job.id) } }
                if job.isFinished { Button("Dismiss") { AppServices.transfers.dismiss(job.id) } }
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 2) {
            if job.state == .failed {
                VIconButton("arrow.clockwise", help: "Retry", size: 26, kind: .flat) { AppServices.transfers.retry(job.id) }
            }
            if job.isActive {
                VIconButton("xmark", help: "Cancel", size: 26, kind: .flat) { AppServices.transfers.cancel(job.id) }
            } else {
                VIconButton("xmark", help: "Dismiss", size: 26, kind: .flat) { AppServices.transfers.dismiss(job.id) }
            }
        }
    }

    /// Second line: the error, the result, "Waiting for a connection (Wi-Fi only?)" or "Unpacking {file}".
    static func detail(_ job: TransferJob) -> String? {
        if job.state == .failed { return job.error }
        if job.kind == .upload { return job.state == .waiting ? "Waiting for a connection" : nil }
        switch job.state {
        case .succeeded:
            var parts = [job.count == 1 ? "1 file extracted" : "\(job.count) files extracted"]
            if let note = job.zipNote, !note.isEmpty { parts.append(note) }
            parts.append("scanning library")
            return parts.joined(separator: " · ")
        case .waiting, .enqueued:
            return "Waiting for a connection (Wi-Fi only?)"
        case .running:
            guard let c = job.current, !c.isEmpty else { return nil }
            return c == "Preparing…" ? c : "Unpacking \(c)"
        default:
            return nil
        }
    }
}

/// A 3 pt bar with an amber segment sliding across (indeterminate progress, flat).
struct IndeterminateBar: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.outline)
                Capsule().fill(Theme.amber).frame(width: w * 0.3).offset(x: -w * 0.3 + phase * w * 1.3)
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}
