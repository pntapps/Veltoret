import SwiftUI
import VeltoretCast
import VeltoretKit
import VeltoretUI

/// The Material "cast" / "cast_connected" glyphs (24×24 paths, as on Windows CastIcons); SF Symbols has no Cast icon.
/// The other cast UI icons use SF Symbols.
public struct CastGlyph: Shape {
    public var connected: Bool
    public init(connected: Bool = false) { self.connected = connected }

    static let cast = "M21 3H3c-1.1 0-2 .9-2 2v3h2V5h18v14h-7v2h7c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zM1 18v3h3c0-1.66-1.34-3-3-3zm0-4v2c2.76 0 5 2.24 5 5h2c0-3.87-3.13-7-7-7zm0-4v2c4.97 0 9 4.03 9 9h2c0-6.08-4.93-11-11-11z"
    static let castConnected = "M1 18v3h3c0-1.66-1.34-3-3-3zm0-4v2c2.76 0 5 2.24 5 5h2c0-3.87-3.13-7-7-7zm18-7H5v1.63c3.96 1.28 7.09 4.41 8.37 8.37H19V7zM1 10v2c4.97 0 9 4.03 9 9h2c0-6.08-4.93-11-11-11zm20-7H3c-1.1 0-2 .9-2 2v3h2V5h18v14h-7v2h7c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2z"

    private static let castPath = SvgPath.parse(cast)
    private static let connectedPath = SvgPath.parse(castConnected)

    public func path(in rect: CGRect) -> Path {
        let base = connected ? Self.connectedPath : Self.castPath
        let scale = min(rect.width, rect.height) / 24
        let dx = rect.minX + (rect.width - 24 * scale) / 2
        let dy = rect.minY + (rect.height - 24 * scale) / 2
        return base.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

/// The cast glyph as a sized, filled view.
struct CastIcon: View {
    var connected = false
    var size: CGFloat = 20
    var color: Color = Theme.text
    var body: some View {
        CastGlyph(connected: connected).fill(color, style: FillStyle(eoFill: false)).frame(width: size, height: size)
    }
}

/// A minimal SVG path-data parser (M L H V C S Z, absolute and relative): enough for the Material glyphs.
enum SvgPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var tokens = Tokenizer(d)
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        while let next = tokens.peekCommand() ?? (tokens.hasNumber ? cmd : nil) {
            if tokens.peekCommand() != nil { tokens.advance() }
            cmd = next
            let rel = cmd.isLowercase
            func pt() -> CGPoint {
                let x = tokens.number(), y = tokens.number()
                return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            switch cmd {
            case "M", "m":
                cur = pt(); start = cur; path.move(to: cur); lastControl = nil
                cmd = rel ? "l" : "L"   // further pairs are line-tos
            case "L", "l":
                cur = pt(); path.addLine(to: cur); lastControl = nil
            case "H", "h":
                let x = tokens.number(); cur.x = rel ? cur.x + x : x; path.addLine(to: cur); lastControl = nil
            case "V", "v":
                let y = tokens.number(); cur.y = rel ? cur.y + y : y; path.addLine(to: cur); lastControl = nil
            case "C", "c":
                let c1 = pt(), c2 = pt(), end = pt()
                path.addCurve(to: end, control1: c1, control2: c2); cur = end; lastControl = c2
            case "S", "s":
                let c1 = lastControl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(), end = pt()
                path.addCurve(to: end, control1: c1, control2: c2); cur = end; lastControl = c2
            case "Z", "z":
                path.closeSubpath(); cur = start; lastControl = nil
            default:
                return path
            }
        }
        return path
    }

    private struct Tokenizer {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" { i += 1 } }

        mutating func peekCommand() -> Character? {
            skip()
            guard i < chars.count, chars[i].isLetter else { return nil }
            return chars[i]
        }

        mutating func advance() { i += 1 }

        var hasNumber: Bool {
            var j = i
            while j < chars.count, chars[j] == " " || chars[j] == "," { j += 1 }
            guard j < chars.count else { return false }
            return chars[j].isNumber || chars[j] == "-" || chars[j] == "."
        }

        mutating func number() -> CGFloat {
            skip()
            var s = ""
            var seenDot = false
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { s.append(c); i += 1 }
                else if c == ".", !seenDot { seenDot = true; s.append(c); i += 1 }
                else { break }
            }
            return CGFloat(Double(s) ?? 0)
        }
    }
}

/// The cast controller's state and devices as published UI state (one subscription shared by every cast view).
@MainActor
public final class CastStateModel: ObservableObject {
    public static let shared = CastStateModel()

    @Published public private(set) var state = CastState()
    @Published public private(set) var devices: [CastDevice] = []
    private let bag = MainBag()
    private var bound = false

    private init() { bind() }

    /// Subscribes to `AppServices.cast` once it exists (idempotent).
    func bind() {
        guard !bound, let cast = AppServices.cast else { return }
        bound = true
        state = cast.state
        devices = cast.devices
        bag.on(cast.stateChanged) { [weak self] _ in self?.state = AppServices.cast.state }
        bag.on(cast.devicesChanged) { [weak self] _ in self?.devices = AppServices.cast.devices }
    }
}
