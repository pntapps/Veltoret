import XCTest
import VeltoretKit
@testable import VeltoretPlayerKit

/// Port of Windows HdrProbeTests.
final class HdrProbeTests: XCTestCase {
    // ---- Matroska builders (EBML: id bytes, 8-byte size, data) ----

    private func idBytes(_ id: UInt32) -> [UInt8] {
        Array([UInt8(id >> 24), UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)].drop(while: { $0 == 0 }))
    }

    private func el(_ id: UInt32, _ children: [UInt8]...) -> [UInt8] { el(id, data: children.flatMap { $0 }) }

    private func el(_ id: UInt32, data: [UInt8]) -> [UInt8] {
        let size = UInt64(UInt32(data.count)) | 0x0100000000000000
        let sizeBytes = (0..<8).map { UInt8((size >> (8 * (7 - UInt64($0)))) & 0xFF) }
        return idBytes(id) + sizeBytes + data
    }

    private func uint(_ id: UInt32, _ value: UInt32) -> [UInt8] {
        el(id, data: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private func unknownSize(_ id: UInt32, _ data: [UInt8]) -> [UInt8] {
        idBytes(id) + [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + data
    }

    private func mkv(_ trackEntry: [UInt8], unknownSegment: Bool = false) -> [UInt8] {
        let ebml = el(0x1A45DFA3, el(0x4282, data: Array("matroska".utf8)))
        let info = el(0x1549A966, uint(0x2AD7B1, 1_000_000))
        let tracks = el(0x1654AE6B, el(0xAE, data: trackEntry), el(0xAE, uint(0x83, 2))) // + an audio track
        let cluster = el(0x1F43B675, data: [UInt8](repeating: 0, count: 64))
        let body = info + tracks + cluster
        return ebml + (unknownSegment ? unknownSize(0x18538067, body) : el(0x18538067, data: body))
    }

    private func videoTrack(_ transfer: UInt32?, dolbyVision: Bool = false) -> [UInt8] {
        var parts = uint(0x83, 1)
        if let t = transfer {
            parts += el(0xE0, uint(0xB0, 3840), el(0x55B0, uint(0x55B1, 9), uint(0x55BA, t)))
        } else {
            parts += el(0xE0, uint(0xB0, 1920))
        }
        if dolbyVision { parts += el(0x41E4, uint(0x41E7, 0x64766343)) }
        return parts
    }

    private func probe(_ file: [UInt8], _ name: String? = nil) async -> HdrFormat {
        await HdrProbe.detect(DataByteSource(Data(file)), fileName: name)
    }

    func testMatroskaColour() async {
        let r1 = await probe(mkv(videoTrack(16))); XCTAssertEqual(.hdr10, r1)
        let r2 = await probe(mkv(videoTrack(18))); XCTAssertEqual(.hlg, r2)
        let r3 = await probe(mkv(videoTrack(1))); XCTAssertEqual(.sdr, r3)
        let r4 = await probe(mkv(videoTrack(16, dolbyVision: true))); XCTAssertEqual(.dolbyVision, r4)
        let r5 = await probe(mkv(videoTrack(16), unknownSegment: true)); XCTAssertEqual(.hdr10, r5)
    }

    func testHeaderWinsOverName_NameIsTheFallback() async {
        // No colour element: the name decides.
        let a = await probe(mkv(videoTrack(nil)), "Movie.2021.2160p.HDR.HEVC.mkv"); XCTAssertEqual(.hdr10, a)
        let b = await probe(mkv(videoTrack(nil)), "Movie.2021.1080p.x264.mkv"); XCTAssertEqual(.unknown, b)
        // The header says SDR: believe it over a misleading name.
        let c = await probe(mkv(videoTrack(1)), "Movie.HDR.mkv"); XCTAssertEqual(.sdr, c)
        // Not a container we read.
        let d = await probe([UInt8](repeating: 0, count: 100), "Movie.2160p.DV.HDR.ts"); XCTAssertEqual(.dolbyVision, d)
    }

    func testFileNames() {
        XCTAssertEqual(.dolbyVision, HdrProbe.fromFileName("Show.S01E01.2160p.DoVi.mkv"))
        XCTAssertEqual(.dolbyVision, HdrProbe.fromFileName("Movie 2023 Dolby Vision 2160p.mkv"))
        XCTAssertEqual(.hdr10, HdrProbe.fromFileName("Movie.2023.2160p.HDR10+.mkv"))
        XCTAssertEqual(.hlg, HdrProbe.fromFileName("Nature.2160p.HLG.mkv"))
        XCTAssertEqual(.unknown, HdrProbe.fromFileName("Movie.2019.DVDRip.mkv"))
        XCTAssertEqual(.unknown, HdrProbe.fromFileName(nil))
    }

    // ---- MP4 builders ----

    private func box(_ type: String, _ children: [UInt8]...) -> [UInt8] {
        let body = children.flatMap { $0 }
        let n = UInt32(body.count + 8)
        return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + Array(type.utf8) + body
    }

    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    private func colr(_ transfer: UInt16) -> [UInt8] {
        box("colr", Array("nclx".utf8) + be16(9) + be16(transfer) + be16(9) + [0])
    }

    private func mp4(_ entry: String, _ extra: [UInt8]?, moovLast: Bool) -> [UInt8] {
        let sampleEntry = box(entry, [UInt8](repeating: 0, count: 78), extra ?? [])
        let stsd = box("stsd", [0, 0, 0, 0, 0, 0, 0, 1], sampleEntry)
        let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))
        let ftyp = box("ftyp", Array("isom".utf8), [0, 0, 0, 0])
        let mdat = box("mdat", [UInt8](repeating: 0, count: 256))
        return moovLast ? ftyp + mdat + moov : ftyp + moov + mdat
    }

    func testMp4Colour() async {
        var r = await probe(mp4("hvc1", colr(16), moovLast: false)); XCTAssertEqual(.hdr10, r)
        r = await probe(mp4("hvc1", colr(16), moovLast: true)); XCTAssertEqual(.hdr10, r)
        r = await probe(mp4("hev1", colr(18), moovLast: false)); XCTAssertEqual(.hlg, r)
        r = await probe(mp4("avc1", colr(1), moovLast: false)); XCTAssertEqual(.sdr, r)
        r = await probe(mp4("dvh1", nil, moovLast: false)); XCTAssertEqual(.dolbyVision, r)
        r = await probe(mp4("hvc1", box("dvcC", [UInt8](repeating: 0, count: 24)), moovLast: false)); XCTAssertEqual(.dolbyVision, r)
        r = await probe(mp4("hvc1", nil, moovLast: false)); XCTAssertEqual(.unknown, r)
    }

    func testLabels() {
        XCTAssertEqual("HDR10", HdrProbe.label(.hdr10))
        XCTAssertEqual("SDR", HdrProbe.label(.unknown))
        XCTAssertTrue(HdrProbe.isHdr(.hlg))
        XCTAssertFalse(HdrProbe.isHdr(.sdr))
    }
}
