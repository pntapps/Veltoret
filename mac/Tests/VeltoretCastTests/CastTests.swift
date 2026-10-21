import XCTest
import VeltoretKit
@testable import VeltoretCast

/// Port of the Windows CastTest.
final class CastTests: XCTestCase {
    private func range(_ h: String, _ total: Int64?) -> [Int64]? {
        CastServer.parseRange(h, total: total).map { [$0.first, $0.last] }
    }

    func testRangesAgainstAKnownSize() {
        XCTAssertEqual(range("bytes=0-", 1000), [0, 999])
        XCTAssertEqual(range("bytes=500-", 1000), [500, 999])
        XCTAssertEqual(range("bytes=100-199", 1000), [100, 199])
        // An end past the file is clipped; the last N bytes work too.
        XCTAssertEqual(range("bytes=900-5000", 1000), [900, 999])
        XCTAssertEqual(range("bytes=-200", 1000), [800, 999])
    }

    func testUnsatisfiableRanges() {
        XCTAssertNil(range("bytes=1000-", 1000))
        XCTAssertNil(range("bytes=300-200", 1000))
        XCTAssertNil(range("items=0-1", 1000))
        XCTAssertNil(range("bytes=abc-", 1000))
    }

    func testOpenRangeOnUnknownSize() {
        XCTAssertEqual(range("bytes=500-", nil), [500, CastServer.openEnd])
        XCTAssertEqual(range("bytes=10-20", nil), [10, 20])
    }

    func testOnlyHomeNetworkClients() {
        XCTAssertTrue(CastServer.isHomeNetwork("192.168.0.125"))
        XCTAssertTrue(CastServer.isHomeNetwork("10.0.0.7"))
        XCTAssertTrue(CastServer.isHomeNetwork("127.0.0.1"))
        XCTAssertTrue(CastServer.isHomeNetwork("fd12:3456::1"))
        XCTAssertFalse(CastServer.isHomeNetwork("8.8.8.8"))
        XCTAssertFalse(CastServer.isHomeNetwork("2001:4860:4860::8888"))
        // Extra: IPv4-mapped IPv6, 172.16/12 edges, link-local.
        XCTAssertTrue(CastServer.isHomeNetwork("::ffff:192.168.1.2"))
        XCTAssertTrue(CastServer.isHomeNetwork("172.31.0.1"))
        XCTAssertFalse(CastServer.isHomeNetwork("172.32.0.1"))
        XCTAssertTrue(CastServer.isHomeNetwork("169.254.10.1"))
        XCTAssertTrue(CastServer.isHomeNetwork("fe80::1"))
        XCTAssertTrue(CastServer.isHomeNetwork("::1"))
    }

    func testWebVttFromCues() {
        let vtt = CastSubtitles.toVtt([
            .init(startUs: 1_000_000, endUs: 2_500_000, text: "Hello"),
            .init(startUs: 3_723_045_000, endUs: 3_725_000_000, text: "Two\n\nlines --> here"),
        ])
        XCTAssertEqual(vtt, "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\n\n01:02:03.045 --> 01:02:05.000\nTwo\nlines -> here\n\n")
    }

    func testWebVttAppliesTheSyncOffset() {
        let lines: [CastSubtitles.Line] = [.init(startUs: 1_000_000, endUs: 2_000_000, text: "Early"),
                                           .init(startUs: 5_000_000, endUs: 6_000_000, text: "Later")]
        XCTAssertEqual(CastSubtitles.toVtt(lines, offsetUs: -1_500_000),
                       "WEBVTT\n\n00:00:00.000 --> 00:00:00.500\nEarly\n\n00:00:03.500 --> 00:00:04.500\nLater\n\n")
        // Cues that end before the start of the video are dropped.
        XCTAssertEqual(CastSubtitles.toVtt([.init(startUs: 0, endUs: 1_000_000, text: "Gone")], offsetUs: -2_000_000), "WEBVTT\n\n")
    }

    func testParsesSrtAndAss() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>Hello</i>\r\nthere\r\n\r\n2\r\n00:01:00,250 --> 00:01:01,000\r\nBye\r\n"
        let cues = CastSubtitles.parse(srt, fileName: "Movie.en.srt")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0], CastSubtitles.Line(startUs: 1_000_000, endUs: 2_500_000, text: "Hello\nthere"))
        XCTAssertEqual(cues[1].startUs, 60_250_000)

        let ass = "[Script Info]\nTitle: x\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" +
            "Dialogue: 0,0:00:01.50,0:00:03.04,Default,,0,0,0,,{\\i1}One, two\\NThree\n"
        let a = CastSubtitles.parse(ass, fileName: "x.ass")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].startUs, 1_500_000)
        XCTAssertEqual(a[0].endUs, 3_040_000)
        XCTAssertEqual(a[0].text, "One, two\nThree")
        XCTAssertEqual(CastSubtitles.languageFromName("Movie.en.srt"), "en")
        XCTAssertEqual(CastSubtitles.languageFromName("Movie.eng.forced.srt"), "eng")
        XCTAssertNil(CastSubtitles.languageFromName("Movie.srt"))
    }

    func testDecodesBomsAndLatin1() {
        let withBom = CastSubtitles.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hé".utf8))
        XCTAssertEqual(withBom.hasPrefix("\u{FEFF}") ? String(withBom.unicodeScalars.dropFirst()) : withBom, "hé")
        XCTAssertEqual(CastSubtitles.parse(withBom + "1\n00:00:01,000 --> 00:00:02,000\nHi\n", fileName: "a.srt").count, 1)
        XCTAssertEqual(CastSubtitles.decode(Data([0xFF, 0xFE, 0x68, 0x00])), "h")
        XCTAssertEqual(CastSubtitles.decode(Data([0x63, 0x61, 0x66, 0xE9])), "café")
    }

    func testMimeTypesAndWarnings() {
        XCTAssertEqual(CastFormats.mimeFor("a.MP4"), "video/mp4")
        XCTAssertEqual(CastFormats.mimeFor("a.m2ts"), "video/mp2t")
        XCTAssertEqual(CastFormats.mimeFor("a.avi"), "video/x-msvideo")
        XCTAssertEqual(CastFormats.mimeFor("a.webm"), "video/webm")
        XCTAssertEqual(CastFormats.mimeFor("Heat (1995)"), "video/x-matroska")
        XCTAssertTrue(CastFormats.audioWarning(nil, "Movie.2160p.TrueHD.Atmos.mkv")!.contains("Dolby TrueHD"))
        XCTAssertTrue(CastFormats.audioWarning(nil, "Movie.DTS-HD.MA.mkv")!.contains("DTS"))
        XCTAssertNil(CastFormats.audioWarning("AC3", "Movie.DTS.mkv"))
        XCTAssertEqual(CastFormats.audioWarning("DTS", nil),
                       "This video's audio is DTS, which most Chromecasts can't play, so there may be no sound. Another version of it may work.")
    }

    func testJavaHashMatchesJava() {
        // "abc".hashCode() == 96354; "hello".hashCode() == 99162322; negative hashes wrap to unsigned.
        XCTAssertEqual(CastFormats.javaHash("abc"), 96354)
        XCTAssertEqual(CastFormats.javaHash("hello"), 99162322)
        // Famous: "polygenelubricants".hashCode() == Integer.MIN_VALUE.
        XCTAssertEqual(CastFormats.javaHash("polygenelubricants"), 2147483648)
        XCTAssertEqual(CastFormats.javaHash("é"), 233)
    }

    func testCastMessageRoundTrips() throws {
        let m = CastMessage(sourceId: "sender-0", destinationId: "receiver-0", namespace: CastMessage.nsHeartbeat, payloadUtf8: "{\"type\":\"PING\"}")
        let frame = [UInt8](m.frame())
        XCTAssertEqual(frame.count - 4, Int(frame[0]) << 24 | Int(frame[1]) << 16 | Int(frame[2]) << 8 | Int(frame[3]))
        // Field order and tags: 08 00 12 .. 1A .. 22 .. 28 00 32 ..
        XCTAssertEqual(frame[4], 0x08)
        XCTAssertEqual(frame[5], 0x00)
        XCTAssertEqual(frame[6], 0x12)
        let back = try CastMessage.decode(Data(frame[4...]))
        XCTAssertEqual(back.sourceId, m.sourceId)
        XCTAssertEqual(back.destinationId, m.destinationId)
        XCTAssertEqual(back.namespace, m.namespace)
        XCTAssertEqual(back.payloadUtf8, m.payloadUtf8)
    }

    func testLoadRequestMatchesTheCastSdk() throws {
        let media = CastMedia(fileId: "f", title: "Heat", subtitle: "S01E02 · Name", posterUrl: "https://image.tmdb.org/t/p/w500/p.jpg",
                              backdropUrl: "https://image.tmdb.org/t/p/w780/b.jpg", isEpisode: true)
        let json = CastLoadRequest.build(requestId: 7, sessionId: "sess", videoUrl: "http://192.168.1.5:5000/t/v1a2",
                                         contentType: "video/x-matroska", media: media, startMs: 754_000,
                                         subtitles: [.init(name: "English", url: "http://192.168.1.5:5000/t/s0-1", language: "en"),
                                                     .init(name: "Other", url: "http://x/s1", language: nil)],
                                         activeSubtitleIndex: 1)
        // Through the wire format and back, as the receiver sees it.
        let r = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: json)) as! [String: Any]
        XCTAssertEqual(r["type"] as? String, "LOAD")
        XCTAssertEqual(r["requestId"] as? Int, 7)
        XCTAssertEqual(r["sessionId"] as? String, "sess")
        XCTAssertEqual(r["autoplay"] as? Bool, true)
        XCTAssertEqual(r["currentTime"] as? Double, 754.0)
        XCTAssertEqual((r["activeTrackIds"] as? [Int])?.first, 2)
        let m = r["media"] as! [String: Any]
        XCTAssertEqual(m["streamType"] as? String, "BUFFERED")
        let metadata = m["metadata"] as! [String: Any]
        XCTAssertEqual(metadata["metadataType"] as? Int, 2)
        XCTAssertEqual((metadata["images"] as? [Any])?.count, 2)
        let tracks = m["tracks"] as! [[String: Any]]
        XCTAssertEqual(tracks[0]["trackId"] as? Int, 1)
        XCTAssertEqual(tracks[0]["type"] as? String, "TEXT")
        XCTAssertEqual(tracks[0]["subtype"] as? String, "SUBTITLES")
        XCTAssertEqual(tracks[0]["trackContentType"] as? String, "text/vtt")
        XCTAssertEqual(tracks[0]["language"] as? String, "en")
        XCTAssertNil(tracks[1]["language"])
        let style = m["textTrackStyle"] as! [String: Any]
        XCTAssertEqual(style["backgroundColor"] as? String, "#00000099")
        XCTAssertEqual(style["edgeType"] as? String, "DROP_SHADOW")
    }

    // ---- The server over a real loopback socket --------------------------------------------------

    func testServesRangesTextAndRefusesBadTokens() async throws {
        let data = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let server = CastServer(open: { _, _ in DataByteSource(data) })
        try server.start("127.0.0.1")
        defer { server.stop() }
        let url = try server.media("v1a0", account: "device", fileId: "x", mime: "video/x-matroska", length: 1000, patches: [105: 0xEE])
        XCTAssertTrue(matches(url, "^http://127\\.0\\.0\\.1:[0-9]+/[0-9a-f]{32}/v1a0$"), url)

        var (head, body) = try await rawHttp(url, range: "bytes=100-199")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 206 Partial Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Range, Content-Type\r\n" +
            "Access-Control-Expose-Headers: Content-Range, Content-Length, Accept-Ranges\r\nConnection: close\r\n" +
            "Content-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\nContent-Length: 100\r\nContent-Range: bytes 100-199/1000"), head)
        XCTAssertEqual(body.count, 100)
        XCTAssertEqual(body[body.startIndex], 100)
        XCTAssertEqual(body[body.startIndex + 5], 0xEE)

        (head, body) = try await rawHttp(url)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertFalse(head.contains("\r\nContent-Range:"))
        XCTAssertEqual(body.count, 1000)

        (head, _) = try await rawHttp(url, range: "bytes=1000-")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 416 Range Not Satisfiable"))
        XCTAssertTrue(head.contains("Content-Range: bytes */1000"))

        (head, body) = try await rawHttp(url, method: "HEAD")
        XCTAssertTrue(head.contains("Content-Length: 1000"))
        XCTAssertTrue(body.isEmpty)

        let vtt = try server.text("s0-1", "WEBVTT\n\n")
        (head, body) = try await rawHttp(vtt)
        XCTAssertTrue(head.contains("Content-Type: text/vtt; charset=utf-8"))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "WEBVTT\n\n")

        (head, body) = try await rawHttp(url.replacingOccurrences(of: server.token, with: String(repeating: "0", count: 32)))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 404 Not Found"))
        XCTAssertTrue(head.hasSuffix("Content-Type: text/plain\r\nContent-Length: 9"))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "Not found")

        (head, body) = try await rawHttp(url, method: "OPTIONS")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 204 No Content"))
        XCTAssertTrue(body.isEmpty)
    }

    func testUnknownSizeStreamsToTheEnd() async throws {
        let data = Data((0..<300).map { UInt8($0 & 0xFF) })
        final class UnknownLength: ByteSource, @unchecked Sendable {
            let inner: DataByteSource
            init(_ d: Data) { inner = DataByteSource(d) }
            var length: Int64 { -1 }
            func read(at offset: Int64, count: Int) async throws -> Data { try await inner.read(at: offset, count: count) }
            func close() {}
        }
        let server = CastServer(open: { _, _ in UnknownLength(data) })
        try server.start("127.0.0.1")
        defer { server.stop() }
        let url = try server.media("v2", account: "device", fileId: "x", mime: "video/mp4", length: nil)
        let (head, body) = try await rawHttp(url, range: "bytes=100-")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 206"))
        XCTAssertTrue(head.contains("Content-Range: bytes 100-/*"))
        XCTAssertEqual(body.count, 200)
    }
}
