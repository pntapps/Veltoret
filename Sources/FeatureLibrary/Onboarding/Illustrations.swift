import SwiftUI
import VeltoretUI

/// Flat vector illustrations for onboarding (Windows Illustrations.cs, Android Illustrations.kt). No gradients.
enum Illustrations {
    static let cream = Color(hex: 0xFFF3E6CF)

    struct PosterStyle {
        let bg: Color, mid: Color, dark: Color, light: Color, style: Int
    }

    static let palette: [PosterStyle] = [
        PosterStyle(bg: Color(hex: 0xFF1F3B3A), mid: Color(hex: 0xFF2E5552), dark: Color(hex: 0xFF142726), light: Theme.amber, style: 0),
        PosterStyle(bg: Color(hex: 0xFF3A2238), mid: Color(hex: 0xFF55304F), dark: Color(hex: 0xFF241522), light: cream, style: 1),
        PosterStyle(bg: Color(hex: 0xFF1E2A44), mid: Color(hex: 0xFF2C3D61), dark: Color(hex: 0xFF131B2C), light: Theme.amberSoft, style: 2),
        PosterStyle(bg: Color(hex: 0xFF4A2A1C), mid: Color(hex: 0xFF6B3D28), dark: Color(hex: 0xFF2E1A11), light: cream, style: 3),
        PosterStyle(bg: Color(hex: 0xFF2A2D35), mid: Color(hex: 0xFF3B3F4A), dark: Color(hex: 0xFF1A1C21), light: Theme.amber, style: 4),
        PosterStyle(bg: Color(hex: 0xFF33361F), mid: Color(hex: 0xFF4A4F2D), dark: Color(hex: 0xFF202213), light: Theme.amberSoft, style: 1),
        PosterStyle(bg: Color(hex: 0xFF2B1F3D), mid: Color(hex: 0xFF3F2E58), dark: Color(hex: 0xFF1B1327), light: Theme.amber, style: 0),
        PosterStyle(bg: Color(hex: 0xFF173238), mid: Color(hex: 0xFF214751), dark: Color(hex: 0xFF0F2125), light: cream, style: 2),
        PosterStyle(bg: Color(hex: 0xFF402024), mid: Color(hex: 0xFF5E2F35), dark: Color(hex: 0xFF281416), light: Theme.amberSoft, style: 4),
    ]
}

/// A 2:3 poster drawing (100×150 units scaled to `width`).
struct IllustrationPoster: View {
    let index: Int
    let width: CGFloat
    var radius: CGFloat = 8

    var body: some View {
        let n = Illustrations.palette.count
        let p = Illustrations.palette[((index % n) + n) % n]
        Canvas { ctx, size in
            let s = size.width / 100
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }
            func oval(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat, _ c: Color, _ o: Double = 1) {
                ctx.fill(Path(ellipseIn: rect(x, y, d, d)), with: .color(c.opacity(o)))
            }
            func poly(_ pts: [(CGFloat, CGFloat)], _ c: Color) {
                var path = Path()
                path.addLines(pts.map { CGPoint(x: $0.0 * s, y: $0.1 * s) })
                path.closeSubpath()
                ctx.fill(path, with: .color(c))
            }
            ctx.fill(Path(rect(0, 0, 100, 150)), with: .color(p.bg))
            switch p.style {
            case 0:
                oval(32, 34, 36, p.light)
                poly([(0, 110), (30, 70), (50, 92), (72, 60), (100, 100), (100, 150), (0, 150)], p.mid)
                poly([(0, 124), (40, 96), (70, 118), (100, 104), (100, 150), (0, 150)], p.dark)
            case 1:
                oval(21, 30, 58, p.light)
                ctx.fill(Path(rect(0, 100, 100, 50)), with: .color(p.mid))
                ctx.fill(Path(rect(0, 98, 100, 4)), with: .color(p.dark))
            case 2:
                oval(70, 20, 14, p.light)
                for (x, w, h) in [(4.0, 16.0, 50.0), (22, 14, 70), (38, 20, 40), (60, 12, 64), (74, 22, 52)] {
                    ctx.fill(Path(rect(x, 120 - h, w, h)), with: .color(p.mid))
                }
                ctx.fill(Path(rect(0, 120, 100, 30)), with: .color(p.dark))
            case 3:
                oval(12, 30, 54, p.mid)
                oval(34, 52, 54, p.light, 0.85)
                oval(30, 70, 30, p.dark)
            default:
                oval(20, 30, 60, p.light)
                oval(44, 52, 12, p.dark)
                poly([(40, 66), (60, 66), (64, 112), (36, 112)], p.dark)
                ctx.fill(Path(rect(0, 112, 100, 38)), with: .color(p.mid))
            }
            ctx.fill(Path(roundedRect: rect(12, 128, 56, 5), cornerRadius: 2.5 * s), with: .color(Illustrations.cream))
            ctx.fill(Path(roundedRect: rect(12, 138, 34, 4), cornerRadius: 2 * s), with: .color(Illustrations.cream.opacity(0.7)))
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Welcome: a wall of drifting posters behind a pulsing amber play disc.
struct PosterWallIllustration: View {
    let size: CGFloat
    @State private var drift = false
    @State private var pulse = false

    var body: some View {
        let tileW = (size - 20 - 30) / 4
        let loopH = 4 * (tileW * 1.5 + 10)
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.surface)
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<4, id: \.self) { i in
                    let up = i % 2 == 0
                    VStack(spacing: 10) {
                        ForEach(0..<8, id: \.self) { j in IllustrationPoster(index: i * 3 + j % 4, width: tileW) }
                    }
                    .offset(y: -tileW * 0.4 + (up ? (drift ? -loopH : 0) : (drift ? 0 : -loopH)))
                    .frame(width: tileW, height: size, alignment: .top)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: size, height: size, alignment: .top)
            Rectangle().fill(Color(hex: 0x590B0B0D))
            ZStack {
                Circle().strokeBorder(Theme.amber, lineWidth: 2).frame(width: 84, height: 84)
                    .scaleEffect(pulse ? 1.7 : 1).opacity(pulse ? 0 : 0.6)
                Circle().fill(Theme.amber).frame(width: 76, height: 76)
                Image(systemName: "play.fill").font(.system(size: 34)).foregroundStyle(Theme.onAmber).offset(x: 3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .vHairline(28)
        .onAppear {
            withAnimation(.linear(duration: 26).repeatForever(autoreverses: false)) { drift = true }
            withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Accounts: a Mac ⇄ cloud with a dashed animated line and a lock / check badge.
struct ConnectIllustration: View {
    let connected: Bool
    @State private var phase: CGFloat = 0
    @State private var pop = false

    var body: some View {
        ZStack {
            // The Mac: a display with 2×2 mini posters and a stand.
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceHigh)
                    .vHairline(12, color: Theme.outlineStrong)
                    .frame(width: 132, height: 92)
                    .overlay(
                        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                            GridRow { IllustrationPoster(index: 2, width: 22, radius: 4); IllustrationPoster(index: 3, width: 22, radius: 4) }
                            GridRow { IllustrationPoster(index: 4, width: 22, radius: 4); IllustrationPoster(index: 5, width: 22, radius: 4) }
                        }
                        .scaleEffect(0.95)
                    )
                Rectangle().fill(Theme.outlineStrong).frame(width: 14, height: 10)
                RoundedRectangle(cornerRadius: 3).fill(Theme.outlineStrong).frame(width: 50, height: 6)
            }
            .position(x: 10 + 66, y: 105)
            // The cloud with a Drive-like triangle.
            Canvas { ctx, _ in
                ctx.fill(Path(ellipseIn: CGRect(x: 20, y: 10, width: 60, height: 60)), with: .color(Theme.surfaceHigh))
                ctx.fill(Path(ellipseIn: CGRect(x: 62, y: 26, width: 48, height: 48)), with: .color(Theme.surfaceHigh))
                ctx.fill(Path(roundedRect: CGRect(x: 10, y: 46, width: 100, height: 34), cornerRadius: 17), with: .color(Theme.surfaceHigh))
                func poly(_ pts: [CGPoint], _ c: Color) { var p = Path(); p.addLines(pts); p.closeSubpath(); ctx.fill(p, with: .color(c)) }
                poly([CGPoint(x: 52, y: 46), CGPoint(x: 64, y: 26), CGPoint(x: 76, y: 46)], Theme.amber)
                poly([CGPoint(x: 46, y: 56), CGPoint(x: 52, y: 46), CGPoint(x: 76, y: 46), CGPoint(x: 70, y: 56)], Theme.amberSoft)
                poly([CGPoint(x: 64, y: 26), CGPoint(x: 70, y: 16), CGPoint(x: 82, y: 36), CGPoint(x: 76, y: 46)], Illustrations.cream)
            }
            .frame(width: 130, height: 90)
            .position(x: 420 - 10 - 65, y: 105)
            // The dashed link.
            Path { p in p.move(to: CGPoint(x: 150, y: 105)); p.addLine(to: CGPoint(x: 290, y: 105)) }
                .stroke(connected ? Theme.amber : Theme.outlineStrong, style: StrokeStyle(lineWidth: 2, dash: [4, 4], dashPhase: phase))
            // The badge.
            ZStack {
                Circle().fill(connected ? Theme.amber : Theme.surface)
                Circle().strokeBorder(connected ? Theme.amber : Theme.outlineStrong, lineWidth: 1)
                Image(systemName: connected ? "checkmark" : "lock.fill").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(connected ? Theme.onAmber : Theme.amberSoft)
            }
            .frame(width: 46, height: 46)
            .scaleEffect(connected && !pop ? 0.6 : 1)
            .position(x: 210, y: 105)
        }
        .frame(width: 420, height: 210)
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { phase = -16 }
            if connected { withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { pop = true } }
        }
    }
}

/// Folders: "Movies" and "TV Shows" folders with posters bobbing out.
struct FoldersIllustration: View {
    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            FolderDrawing(label: "Movies", icon: "film", posterBase: 0, delay: 0)
            FolderDrawing(label: "TV Shows", icon: "tv", posterBase: 4, delay: 0.75)
        }
        .frame(height: 200)
    }
}

private struct FolderDrawing: View {
    let label: String
    let icon: String
    let posterBase: Int
    let delay: Double
    @State private var bob = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0xFF6B4D22))
                    .frame(width: 138, height: 110).offset(x: 6, y: 30)
                UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).fill(Color(hex: 0xFF6B4D22))
                    .frame(width: 54, height: 16).offset(x: 6, y: 18)
                ForEach(0..<2, id: \.self) { i in
                    IllustrationPoster(index: posterBase + i, width: 46, radius: 5)
                        .offset(x: 30 + CGFloat(i) * 46, y: 34 + (bob ? -14 : 0))
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true).delay(delay + Double(i) * 0.4), value: bob)
                }
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.amber)
                    .frame(width: 150, height: 70)
                    .overlay(Image(systemName: icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.onAmber))
                    .offset(y: 70)
            }
            .frame(width: 150, height: 150, alignment: .topLeading)
            .clipped()
            Text(label).vLabelLarge(Theme.textMuted)
        }
        .onAppear { bob = true }
    }
}

/// TMDB step: three fanned posters swaying, a rating chip and a turning key disc.
struct MetadataIllustration: View {
    @State private var sway = false
    @State private var turn = false

    var body: some View {
        ZStack {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    IllustrationPoster(index: i * 2 + 1, width: 92, radius: 10)
                        .rotationEffect(.degrees(Double(i - 1) * 14), anchor: .bottom)
                        .offset(x: CGFloat(i - 1) * 35)
                }
            }
            .frame(width: 200, height: 200)
            .rotationEffect(.degrees(sway ? 3 : -3), anchor: .bottom)
            Text("★ 8.6").vLabelLarge(Theme.amber)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceHigh))
                .vHairline(10, color: Theme.outlineStrong)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 20).padding(.trailing, 10)
            Circle().fill(Theme.amber).frame(width: 50, height: 50)
                .overlay(Image(systemName: "key.fill").font(.system(size: 22)).foregroundStyle(Theme.onAmber))
                .rotationEffect(.degrees(turn ? 20 : -20))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 18).padding(.bottom, 14)
        }
        .frame(width: 340, height: 210)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { sway = true }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { turn = true }
        }
    }
}

/// Scan: 4×2 poster slots revealed one by one, with an amber scan line until finished.
struct ScanIllustration: View {
    let finished: Bool
    @State private var sweep = false

    var body: some View {
        ZStack(alignment: .top) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: finished)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.8)
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(0..<2, id: \.self) { r in
                        GridRow {
                            ForEach(0..<4, id: \.self) { c in
                                let i = r * 4 + c
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceHigh)
                                    IllustrationPoster(index: i, width: 94).opacity(finished ? 1 : Self.reveal(i, t))
                                }
                                .frame(width: 94, height: 141)
                            }
                        }
                    }
                }
            }
            if !finished {
                Rectangle().fill(Theme.amber).frame(height: 2)
                    .offset(y: sweep ? 141 * 2 + 12 : 0)
                    .onAppear { withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { sweep = true } }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.surface))
        .vHairline(24)
    }

    static func reveal(_ i: Int, _ t: Double) -> Double {
        let start = Double(i) * 0.5
        if t < start { return 0 }
        if t < start + 0.35 { return (t - start) / 0.35 }
        if t < 4.5 { return 1 }
        return max(0, 1 - (t - 4.5) / 0.3)
    }
}
