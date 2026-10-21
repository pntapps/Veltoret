import XCTest
import VeltoretKit
@testable import VeltoretCast

/// Port of the Windows CastAudioTest.
final class CastAudioTests: XCTestCase {
    // Minimal EBML writer: element = id bytes + 8-byte size + data.
    private func el(_ id: Int64, _ children: [UInt8]...) -> [UInt8] {
        let data = children.flatMap { $0 }
        var out: [UInt8] = []
        var idBytes: [UInt8] = []
        var v = id
        while v > 0 { idBytes.append(UInt8(v & 0xFF)); v >>= 8 }
        out += idBytes.reversed()
        out.append(0x01) // 8-byte size marker
        for i in stride(from: 6, through: 0, by: -1) { out.append(UInt8((Int64(data.count) >> (8 * Int64(i))) & 0xFF)) }
        return out + data
    }

    private func uint(_ id: Int64, _ v: Int64) -> [UInt8] { el(id, [UInt8(v)]) }
    private func track(_ number: Int64, _ type: Int64) -> [UInt8] { el(0xAE, uint(0xD7, number), uint(0x83, type)) }
    private var header: [UInt8] { el(0x1A45DFA3, uint(0x4286, 1)) }
    private func segment(_ children: [UInt8]...) -> [UInt8] { header + el(0x18538067, children.flatMap { $0 }) }
    private var cluster: [UInt8] { el(0x1F43B675, uint(0xE7, 0)) }

    private func reader(_ bytes: [UInt8]) -> CastAudio.Reader {
        { position, length in
            let from = Int(min(position, Int64(bytes.count)))
            let to = Int(min(position + Int64(length), Int64(bytes.count)))
            return Data(bytes[from..<to])
        }
    }

    func testFindsAudioTracksBeforeTheFirstCluster() async {
        let file = segment(el(0x1654AE6B, track(1, 1), track(2, 2), track(3, 2), track(4, 0x11)), cluster)
        let tracks = await CastAudio.audioTracks(reader(file))
        XCTAssertEqual(tracks.map(\.number), [2, 3])
        for t in tracks { XCTAssertEqual(file[Int(t.typeOffset)], 2) }
    }

    func testFollowsTheSeekHeadToTracksStoredAfterACluster() async {
        // SeekHead says Tracks is at (segment-relative) offset = seekHead + cluster sizes.
        func seekHead(_ position: Int64) -> [UInt8] {
            el(0x114D9B74, el(0x4DBB, el(0x53AB, [0x16, 0x54, 0xAE, 0x6B]), uint(0x53AC, position)))
        }
        let tracks = el(0x1654AE6B, track(1, 1), track(2, 2), track(3, 2))
        let headSize = Int64(seekHead(0).count)
        let file = segment(seekHead(headSize + Int64(cluster.count)), cluster, tracks)
        let found = await CastAudio.audioTracks(reader(file))
        XCTAssertEqual(found.map(\.number), [2, 3])
    }

    func testNothingForOtherFormatsOrASingleTrack() async {
        let none = await CastAudio.audioTracks(reader([UInt8](repeating: 7, count: 4096)))
        XCTAssertTrue(none.isEmpty)
        let one = await CastAudio.audioTracks(reader(segment(el(0x1654AE6B, track(1, 1), track(2, 2)))))
        XCTAssertTrue(CastAudio.hideAllBut(one, keep: 2).isEmpty)
    }

    func testHidesEveryOtherAudioTrackAcrossBufferBoundaries() async {
        let file = segment(el(0x1654AE6B, track(1, 1), track(2, 2), track(3, 2), track(4, 2)))
        let tracks = await CastAudio.audioTracks(reader(file))
        let patches = CastAudio.hideAllBut(tracks, keep: 3)
        XCTAssertEqual(patches.count, 2)
        // Stream it in odd-sized chunks, as the server does.
        var streamed: [UInt8] = []
        var p = 0
        while p < file.count {
            let n = min(7, file.count - p)
            var chunk = Data(file[p..<(p + n)])
            CastAudio.apply(patches, position: Int64(p), buffer: &chunk)
            streamed += chunk
            p += n
        }
        let result = await CastAudio.audioTracks(reader(streamed))
        XCTAssertEqual(result.map(\.number), [3])
        XCTAssertEqual(streamed.count, file.count)
    }

    func testReadsLanguageAndCodecWhenPresent() async {
        func str(_ id: Int64, _ s: String) -> [UInt8] { el(id, Array(s.utf8)) }
        let file = segment(el(0x1654AE6B,
                              el(0xAE, uint(0xD7, 1), uint(0x83, 2), str(0x86, "A_DTS"), str(0x22B59C, "eng")),
                              el(0xAE, uint(0xD7, 2), uint(0x83, 2), str(0x86, "A_AC3"), str(0x22B59C, "fre"))))
        let tracks = await CastAudio.audioTracks(reader(file))
        XCTAssertEqual(tracks[0].language, "eng")
        XCTAssertEqual(tracks[0].codecId, "A_DTS")
        XCTAssertEqual(tracks[1].language, "fre")
        XCTAssertEqual(LanguageNames.name("fre"), "French")
        XCTAssertEqual(LanguageNames.toTwoLetter("fre"), "fr")
        XCTAssertEqual(CastMediaFactory.codecName("A_DTS"), "DTS")
    }

    func testByteSourceReaderReadsWindows() async {
        let file = segment(el(0x1654AE6B, track(1, 1), track(2, 2), track(3, 2)))
        let tracks = await CastAudio.audioTracks(CastAudio.reader(DataByteSource(Data(file))))
        XCTAssertEqual(tracks.map(\.number), [2, 3])
    }
}
