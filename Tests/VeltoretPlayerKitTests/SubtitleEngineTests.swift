import XCTest
import VeltoretKit
@testable import VeltoretPlayerKit

/// Port of Windows SubtitleEngineTests (Android SubtitleEngineDeviceTest).
final class SubtitleEngineTests: XCTestCase {
    private let srt = "1\n00:00:01,000 --> 00:00:03,000\nCafé au lait, señor.\n\n2\n00:00:04,000 --> 00:00:06,500\n<i>Second line</i>"

    private func text(_ cues: [SubtitleCue], _ ms: Int64, _ offsetMs: Int64 = 0) -> String {
        SubtitleEngine.activeAt(cues, ms, offsetMs).map(\.text).joined(separator: " ")
    }

    private func enc(_ s: String, _ codePage: Int) -> Data { s.data(using: SubtitleEngine.windowsCodePage(codePage))! }

    func testParsesUtf8Srt() throws {
        let cues = try SubtitleEngine.parse(Data(srt.utf8), fileName: "movie.srt")
        XCTAssertEqual(2, cues.count)
        XCTAssertEqual("Café au lait, señor.", text(cues, 2_000))
        XCTAssertEqual("", text(cues, 3_500))
        XCTAssertEqual("Second line", text(cues, 5_000))
    }

    func testLegacyWindowsEncodingIsTranscoded() throws {
        let bytes = enc(srt, 1252)
        XCTAssertNil(String(data: bytes, encoding: .utf8))
        XCTAssertEqual("Café au lait, señor.", text(try SubtitleEngine.parse(bytes, fileName: "movie.srt"), 2_000))
        let normalized = SubtitleEngine.normalizeText(bytes)
        XCTAssertTrue(String(data: normalized, encoding: .utf8)!.contains("Café"))
    }

    func testLegacyCyrillicAndArabicAreDetected() throws {
        let ruText = "Привет, как дела? Это проверка субтитров."
        let ru = "1\n00:00:01,000 --> 00:00:03,000\n" + ruText + "\n"
        XCTAssertEqual(ruText, text(try SubtitleEngine.parse(enc(ru, 1251), fileName: "a.srt"), 2_000))

        let arText = "مرحبا بكم في هذا الفيلم الجميل"
        let ar = "1\n00:00:01,000 --> 00:00:03,000\n" + arText + "\n"
        XCTAssertEqual(arText, text(try SubtitleEngine.parse(enc(ar, 1256), fileName: "a.srt"), 2_000))
    }

    func testBomsAreKept() throws {
        let utf8Bom = Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8)
        XCTAssertEqual(utf8Bom, SubtitleEngine.normalizeText(utf8Bom))
        let utf16 = Data([0xFF, 0xFE]) + srt.data(using: .utf16LittleEndian)!
        XCTAssertEqual(utf16, SubtitleEngine.normalizeText(utf16))
        XCTAssertEqual("Second line", text(try SubtitleEngine.parse(utf16, fileName: "a.srt"), 5_000))
        let utf16be = Data([0xFE, 0xFF]) + srt.data(using: .utf16BigEndian)!
        XCTAssertEqual("Second line", text(try SubtitleEngine.parse(utf16be, fileName: "a.srt"), 5_000))
    }

    func testUtf8OutputHasBom() {
        let bytes = SubtitleEngine.toUtf8WithBom(enc(srt, 1252))
        XCTAssertEqual([0xEF, 0xBB, 0xBF], [UInt8](bytes.prefix(3)))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("señor"))
    }

    func testOffsetShiftsCues() throws {
        let cues = try SubtitleEngine.parse(Data(srt.utf8), fileName: "movie.srt")
        // +2 s: the first line now shows between 3 s and 5 s.
        XCTAssertEqual("", text(cues, 2_000, 2_000))
        XCTAssertEqual("Café au lait, señor.", text(cues, 4_000, 2_000))
        // −1 s: the second line shows from 3 s.
        XCTAssertEqual("Second line", text(cues, 3_200, -1_000))
    }

    func testParsesWebVttAndAss() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n"
        XCTAssertEqual("Hello", text(try SubtitleEngine.parse(Data(vtt.utf8), fileName: "a.vtt"), 1_500))

        let shortVtt = "WEBVTT\n\nintro\n00:01.000 --> 00:02.500 align:start\nShort clock\n"
        XCTAssertEqual("Short clock", text(try SubtitleEngine.parse(Data(shortVtt.utf8), fileName: "a.vtt"), 2_000))

        let ass = """
            [Script Info]
            ScriptType: v4.00+

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\i1}Anime line, with a comma
            """
        XCTAssertTrue(text(try SubtitleEngine.parse(Data(ass.utf8), fileName: "ep.ass"), 1_500).contains("Anime line, with a comma"))
    }

    func testParsesTtml() throws {
        let ttml = """
            <?xml version="1.0" encoding="utf-8"?>
            <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
              <p begin="00:00:01.000" end="00:00:02.000">One<br/>Two</p>
              <p begin="3s" dur="1s">Three</p>
            </div></body></tt>
            """
        let cues = try SubtitleEngine.parse(Data(ttml.utf8), fileName: "a.dfxp")
        XCTAssertEqual("One\nTwo", text(cues, 1_500))
        XCTAssertEqual("Three", text(cues, 3_500))
        XCTAssertEqual("", text(cues, 4_500))
    }

    func testOpenEndsCloseAtNextCueOrAfterFiveSeconds() throws {
        let ttml = #"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1s">A</p><p begin="4s">B</p></div></body></tt>"#
        let cues = try SubtitleEngine.parse(Data(ttml.utf8), fileName: "a.ttml")
        XCTAssertEqual(4_000, cues[0].endMs)
        XCTAssertEqual(9_000, cues[1].endMs)
    }

    func testBrokenTtmlIsUnsupported() {
        XCTAssertThrowsError(try SubtitleEngine.parse(Data("<tt><p>".utf8), fileName: "a.ttml")) {
            XCTAssertEqual("This subtitle format isn't supported", ($0 as? SubtitleError)?.message)
        }
    }

    func testEmptyFileHasNoCues() throws {
        XCTAssertTrue(try SubtitleEngine.parse(Data("nothing here".utf8), fileName: "a.srt").isEmpty)
    }

    func testTooLargeIsRejected() {
        XCTAssertThrowsError(try SubtitleEngine.parse(Data(count: SubtitleEngine.maxBytes + 1), fileName: "a.srt")) {
            XCTAssertEqual("That file is too large to be a subtitle", ($0 as? SubtitleError)?.message)
            XCTAssertEqual("That file is too large to be a subtitle", $0.localizedDescription)
        }
    }

    /// A source that hides its length, so readLimited has to count.
    private final class UnknownLength: ByteSource, @unchecked Sendable {
        let inner: DataByteSource
        init(_ d: Data) { inner = DataByteSource(d) }
        var length: Int64 { -1 }
        func read(at offset: Int64, count: Int) async throws -> Data { try await inner.read(at: offset, count: count) }
        func close() {}
    }

    func testReadLimitedStopsAtTheLimit() async throws {
        do {
            _ = try await SubtitleEngine.readLimited(UnknownLength(Data(count: SubtitleEngine.maxBytes + 10)))
            XCTFail("expected an error")
        } catch let e as SubtitleError {
            XCTAssertEqual(SubtitleEngine.tooLarge, e.message)
        }
        do {
            _ = try await SubtitleEngine.readLimited(DataByteSource(Data(count: SubtitleEngine.maxBytes + 10)))
            XCTFail("expected an error")
        } catch is SubtitleError {}
        let small = try await SubtitleEngine.readLimited(DataByteSource(Data(count: 100)))
        XCTAssertEqual(100, small.count)
    }

    func testOverlappingCuesShowTogether() throws {
        let s = "1\n00:00:01,000 --> 00:00:05,000\nA\n\n2\n00:00:02,000 --> 00:00:03,000\nB\n"
        XCTAssertEqual("A B", text(try SubtitleEngine.parse(Data(s.utf8), fileName: "a.srt"), 2_500))
    }

    func testCrLfLineEnds() throws {
        let s = srt.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual("Second line", text(try SubtitleEngine.parse(Data(s.utf8), fileName: "a.srt"), 5_000))
    }
}
