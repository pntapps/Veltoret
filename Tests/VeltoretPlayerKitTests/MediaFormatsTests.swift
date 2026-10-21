import XCTest
@testable import VeltoretPlayerKit

/// Port of Windows MediaFormatsTests (Android MediaFormatsDeviceTest plus the codec and language mapping).
final class MediaFormatsTests: XCTestCase {
    func testReleaseGroupLabelsAreHidden() {
        XCTAssertNil(MediaFormats.cleanLabel("ReleaseSite.ai.in"))
        XCTAssertNil(MediaFormats.cleanLabel("www.example.com"))
        XCTAssertNil(MediaFormats.cleanLabel("Encoded by x@y"))
        XCTAssertEqual("SDH", MediaFormats.cleanLabel("SDH"))
        XCTAssertEqual("Director's Commentary", MediaFormats.cleanLabel("Director's Commentary"))
        XCTAssertEqual("Dub.Intl", MediaFormats.cleanLabel("Dub.Intl")) // ".in" inside a word is not a domain
        XCTAssertNil(MediaFormats.cleanLabel("ReleaseSite.at"))
        XCTAssertNil(MediaFormats.cleanLabel("ExampleRips.town"))
        XCTAssertEqual("DTS-HD.MA 5.1", MediaFormats.cleanLabel("DTS-HD.MA 5.1"))
        XCTAssertEqual("H.264", MediaFormats.cleanLabel("H.264"))
        XCTAssertNil(MediaFormats.cleanLabel("   "))
        XCTAssertNil(MediaFormats.cleanLabel(nil))
        XCTAssertEqual("SDH", MediaFormats.cleanLabel("  SDH "))
    }

    func testDuplicateLanguagesAreNumbered() {
        let names = ["hi": "Hindi", "en": "English"]
        let titles = MediaFormats.trackTitles(
            [("hi", "ReleaseSite.ai.in"), ("hi", nil), ("en", nil), (nil, "Commentary"), (nil, nil)],
            fallback: "Subtitle", language: { $0 == nil ? nil : names[$0!] })
        XCTAssertEqual(["Hindi 1", "Hindi 2", "English", "Commentary", "Subtitle 5"], titles)
    }

    func testLanguageNames() {
        let cases = [("en", "English"), ("eng", "English"), ("hin", "Hindi"), ("fre", "French"), ("fra", "French"),
                     ("ger", "German"), ("deu", "German"), ("en-US", "English"), ("xx", "XX")]
        for (code, expected) in cases { XCTAssertEqual(expected, MediaFormats.languageName(code), code) }
    }

    func testUndeterminedLanguageHasNoName() {
        XCTAssertNil(MediaFormats.languageName("und"))
        XCTAssertNil(MediaFormats.languageName(""))
        XCTAssertNil(MediaFormats.languageName(nil))
    }

    func testLanguagesNormalise() {
        let cases = [("eng", "en"), ("EN", "en"), ("en-US", "en"), ("fre", "fr"), ("hin", "hi"), ("chi", "zh")]
        for (code, expected) in cases { XCTAssertEqual(expected, MediaFormats.normalizeLanguage(code), code) }
    }

    func testUndNormalisesToNull() { XCTAssertNil(MediaFormats.normalizeLanguage("und")) }

    func testFourCcs() {
        let h264 = UInt32(UInt8(ascii: "h")) | UInt32(UInt8(ascii: "2")) << 8 | UInt32(UInt8(ascii: "6")) << 16 | UInt32(UInt8(ascii: "4")) << 24
        XCTAssertEqual("h264", MediaFormats.fourCC(h264))
        XCTAssertEqual("H.264", MediaFormats.videoCodec("h264"))
        XCTAssertEqual("HEVC", MediaFormats.videoCodec("hevc"))
        XCTAssertEqual("Dolby Digital", MediaFormats.audioCodec("a52 "))
        XCTAssertEqual("Dolby Digital+", MediaFormats.audioCodec("eac3"))
        XCTAssertEqual("DTS", MediaFormats.audioCodec("dts "))
        XCTAssertEqual("Dolby TrueHD", MediaFormats.audioCodec("mlp "))
        XCTAssertEqual("AAC", MediaFormats.audioCodec("mp4a"))
        XCTAssertEqual("MP3", MediaFormats.audioCodec("mpga"))
        XCTAssertEqual("PCM", MediaFormats.audioCodec("s16l"))
        XCTAssertEqual("XYZW", MediaFormats.audioCodec("xyzw"))
        XCTAssertEqual("ASS", MediaFormats.subtitleFormat("ssa "))
        XCTAssertEqual("SRT", MediaFormats.subtitleFormat("subt"))
        XCTAssertEqual("PGS", MediaFormats.subtitleFormat("pgs "))
        XCTAssertNil(MediaFormats.subtitleFormat("abcd"))
    }

    func testInfoValues() {
        XCTAssertNil(MediaFormats.channels(0))
        XCTAssertEqual("Mono", MediaFormats.channels(1))
        XCTAssertEqual("Stereo", MediaFormats.channels(2))
        XCTAssertEqual("5.1", MediaFormats.channels(6))
        XCTAssertEqual("7.1", MediaFormats.channels(8))
        XCTAssertEqual("3 ch", MediaFormats.channels(3))
        XCTAssertEqual("3840×2160 · 4K", MediaFormats.resolution(3840, 2160))
        XCTAssertEqual("1920×800 · 1080p", MediaFormats.resolution(1920, 800))
        XCTAssertEqual("1280×720 · 720p", MediaFormats.resolution(1280, 720))
        XCTAssertEqual("640×480 · SD", MediaFormats.resolution(640, 480))
        XCTAssertEqual("24.0 fps", MediaFormats.frameRate(23.976))
        XCTAssertEqual("30.0 fps", MediaFormats.frameRate(29.97))
        XCTAssertEqual("120 fps", MediaFormats.frameRate(120))
        XCTAssertEqual("5.00 fps", MediaFormats.frameRate(5))
        XCTAssertEqual("12.3 Mbps", MediaFormats.bitrate(12_300_000))
        XCTAssertEqual("640 kbps", MediaFormats.bitrate(640_500))
        XCTAssertEqual("48.0 kHz", MediaFormats.sampleRate(48000))
        XCTAssertEqual("44.1 kHz", MediaFormats.sampleRate(44100))
    }
}
