import AppKit
import CoreText
import SwiftUI
import VeltoretKit

/// The bundled fonts (SIL OFL 1.1, `third_party/fonts/OFL.txt`): Fraunces (variable serif) for titles, Inter
/// (variable) for everything else. Call `Fonts.register()` once at launch (`VeltoretUIModule.initialize()` does).
///
/// Both are variable fonts; instances are built with variation axes so titles match Android exactly
/// (Fraunces `wght`=600, `opsz`=72, `SOFT`=50; Inter `wght` 400/500/600/700).
public enum Fonts {
    public static let serifFamily = "Fraunces"
    public static let sansFamily = "Inter"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered = false
    nonisolated(unsafe) private static var serifBase: CTFontDescriptor?
    nonisolated(unsafe) private static var sansBase: CTFontDescriptor?
    nonisolated(unsafe) private static var cache: [String: CTFont] = [:]

    // Axis tags as 4-char codes.
    private static let wght: UInt32 = 0x7767_6874 // 'wght'
    private static let opsz: UInt32 = 0x6F70_737A // 'opsz'
    private static let soft: UInt32 = 0x534F_4654 // 'SOFT'

    /// Registers both TTFs for the process (CTFontManagerRegisterFontsForURL). Idempotent.
    public static func register() {
        lock.lock(); defer { lock.unlock() }
        if registered { return }
        registered = true
        for name in ["fraunces", "inter"] {
            guard let url = fontURL(name) else { Log.error("Font \(name).ttf missing from the bundle"); continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered is fine.
                if let e = error?.takeRetainedValue() { Log.info("Font \(name): \(e)") }
            }
            if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                // Prefer the "Regular" named instance as the base; variations are applied on top.
                let regular = descs.first { d in
                    let n = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String ?? ""
                    return n.hasSuffix("-Regular")
                } ?? descs.first
                if name == "fraunces" { serifBase = regular } else { sansBase = regular }
            }
        }
    }

    private static func fontURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.module.url(forResource: name, withExtension: "ttf")
    }

    private static func ctFont(serif: Bool, size: CGFloat, weight: CGFloat) -> CTFont {
        register()
        let key = "\(serif ? "s" : "n")|\(size)|\(weight)"
        lock.lock()
        if let f = cache[key] { lock.unlock(); return f }
        let base = serif ? serifBase : sansBase
        lock.unlock()
        let font: CTFont
        if let base {
            var variation: [NSNumber: NSNumber] = [NSNumber(value: wght): NSNumber(value: Double(weight))]
            if serif {
                variation[NSNumber(value: opsz)] = 72
                variation[NSNumber(value: soft)] = 50
            } else {
                variation[NSNumber(value: opsz)] = NSNumber(value: Double(min(32, max(14, size))))
            }
            let attrs: [CFString: Any] = [kCTFontVariationAttribute: variation]
            let desc = CTFontDescriptorCreateCopyWithAttributes(base, attrs as CFDictionary)
            font = CTFontCreateWithFontDescriptor(desc, size, nil)
        } else {
            let fallback = serif ? NSFont(name: "Georgia-Bold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
                                 : NSFont.systemFont(ofSize: size, weight: NSFont.Weight(rawValue: (weight - 400) / 500))
            font = fallback as CTFont
        }
        lock.lock(); cache[key] = font; lock.unlock()
        return font
    }

    /// Fraunces title font (default weight 600 = SemiBold).
    public static func serif(_ size: CGFloat, weight: CGFloat = 600) -> Font {
        Font(ctFont(serif: true, size: size, weight: weight))
    }

    /// Inter at the given SwiftUI weight.
    public static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(ctFont(serif: false, size: size, weight: numeric(weight)))
    }

    /// AppKit versions (NSTextField, attributed strings).
    public static func nsSerif(_ size: CGFloat, weight: CGFloat = 600) -> NSFont {
        ctFont(serif: true, size: size, weight: weight) as NSFont
    }

    public static func nsSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        ctFont(serif: false, size: size, weight: numeric(weight)) as NSFont
    }

    static func numeric(_ w: Font.Weight) -> CGFloat {
        switch w {
        case .ultraLight: return 200
        case .thin: return 100
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }
}
