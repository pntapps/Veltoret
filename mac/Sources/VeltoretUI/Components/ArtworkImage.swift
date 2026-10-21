import AppKit
import ImageIO
import SwiftUI
import VeltoretKit

/// Loads artwork (TMDB URLs or local file URLs) through `AppServices.images` (download once, works offline), decodes
/// it off the main thread at the size needed, and keeps decoded images in a small memory cache.
public enum ArtworkLoader {
    /// Turns a remote URL into a local file (default: `AppServices.images.file(for:)`). Tests may replace it.
    nonisolated(unsafe) public static var resolveFile: (String) async -> URL? = { url in
        if url.hasPrefix("/") { return URL(fileURLWithPath: url) }
        if url.hasPrefix("file://") { return URL(string: url) }
        return await defaultResolve(url)
    }

    private static let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    /// A decoded image already in memory (no I/O).
    public static func cached(_ url: String, maxPixel: Int) -> NSImage? {
        memory.object(forKey: "\(maxPixel)|\(url)" as NSString)
    }

    /// Loads and decodes `url`, downsampled so its longest side is at most `maxPixel` pixels. Nil when unavailable.
    public static func load(_ url: String, maxPixel: Int) async -> NSImage? {
        let key = "\(maxPixel)|\(url)" as NSString
        if let img = memory.object(forKey: key) { return img }
        guard let file = await resolveFile(url) else { return nil }
        let img = await Task.detached(priority: .userInitiated) { decode(file, maxPixel: maxPixel) }.value
        if let img { memory.setObject(img, forKey: key) }
        return img
    }

    static func decode(_ file: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// An image box that loads `url` via `ArtworkLoader` (→ `AppServices.images`), cropped to fill its frame
/// (Android `VImage`, Windows `AsyncImage`).
///
/// While loading it shows a flat SurfaceHigh placeholder that "breathes" (alpha 0.55 ↔ 1, 900 ms). With no URL (or a
/// failed load) and a `fallbackText`, it shows that text centered in the serif titleMedium style, TextMuted, max 4 lines.
/// Give it a frame / aspect ratio from outside: `ArtworkImage(url: poster, fallbackText: title).aspectRatio(2/3, contentMode: .fit)`.
public struct ArtworkImage: View {
    let url: String?
    let fallbackText: String?
    let cornerRadius: CGFloat
    let outlined: Bool
    let maxPixel: Int
    let contentMode: ContentMode

    @State private var image: NSImage?
    @State private var failed = false
    @State private var pulse = false

    /// - Parameters:
    ///   - url: TMDB image URL (see `TmdbImages`), a local path or file URL; nil shows the fallback.
    ///   - cornerRadius: clip radius (posters 12, wide cards 14).
    ///   - outlined: draws the 1 pt Outline hairline.
    ///   - maxPixel: decode size (longest side, pixels). Posters ~520, backdrops ~1600.
    public init(url: String?, fallbackText: String? = nil, cornerRadius: CGFloat = 0, outlined: Bool = false,
                maxPixel: Int = 700, contentMode: ContentMode = .fill) {
        self.url = url; self.fallbackText = fallbackText; self.cornerRadius = cornerRadius; self.outlined = outlined
        self.maxPixel = maxPixel; self.contentMode = contentMode
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            Theme.surfaceHigh
                .opacity(image == nil && url != nil && !failed ? (pulse ? 0.55 : 1) : 1)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else if (url == nil || failed), let fallbackText, !fallbackText.isEmpty {
                Text(fallbackText)
                    .font(Fonts.serif(16))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(12)
            }
        }
        .clipShape(shape)
        .overlay(outlined ? shape.strokeBorder(Theme.outline, lineWidth: 1) : nil)
        .task(id: "\(url ?? "")|\(maxPixel)") { await load() }
    }

    private func load() async {
        failed = false
        guard let url, !url.isEmpty else { image = nil; return }
        if let hit = ArtworkLoader.cached(url, maxPixel: maxPixel) { image = hit; return }
        image = nil
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        let img = await ArtworkLoader.load(url, maxPixel: maxPixel)
        if Task.isCancelled { return }
        withAnimation(.easeOut(duration: 0.2)) {
            pulse = false
            image = img
            failed = img == nil
        }
    }
}

/// A 2:3 poster image with corner 12 and the Outline hairline.
public struct AsyncPoster: View {
    let url: String?
    let title: String?
    public init(url: String?, title: String? = nil) { self.url = url; self.title = title }
    public var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay(ArtworkImage(url: url, fallbackText: title, cornerRadius: Theme.Radius.poster, outlined: true, maxPixel: 520))
    }
}
