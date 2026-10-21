import XCTest
import VeltoretKit
@testable import VeltoretCast

/// Port of the Windows CastControllerTest. End-to-end over loopback: a fake Chromecast (TLS with a self-signed
/// certificate + Cast v2 framing) and the real controller and server.
final class CastControllerTests: XCTestCase {
    final class FakeChromecast: @unchecked Sendable {
        private let lock = NSLock()
        private var _received: [[String: Any]] = []
        private var _loaded: [String: Any]?
        var server: LoopbackServer!
        var port: Int { server.port }

        var received: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _received }
        var loaded: [String: Any]? { lock.lock(); defer { lock.unlock() }; return _loaded }

        init(identity: SecIdentity) throws {
            server = try LoopbackServer(identity: identity) { [weak self] c in await self?.serve(c) }
        }

        private func serve(_ c: NetConnection) async {
            var launched = false
            do {
                while true {
                    let header = [UInt8](try await c.receiveExactly(4))
                    let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
                    let m = try CastMessage.decode(try await c.receiveExactly(length))
                    let json = try JSONSerialization.jsonObject(with: Data(m.payloadUtf8!.utf8)) as! [String: Any]
                    lock.lock(); _received.append(json); lock.unlock()
                    let type = json["type"] as? String
                    let rid = (json["requestId"] as? Int) ?? 0
                    func reply(_ ns: String, _ payload: String) async throws {
                        try await c.send(CastMessage(sourceId: m.destinationId, destinationId: m.sourceId, namespace: ns, payloadUtf8: payload).frame())
                    }
                    switch type {
                    case "PING":
                        try await reply(CastMessage.nsHeartbeat, "{\"type\":\"PONG\"}")
                    case "LAUNCH", "GET_STATUS" where m.namespace == CastMessage.nsReceiver:
                        if type == "LAUNCH" { launched = true }
                        let apps = launched ? "[{\"appId\":\"CC1AD845\",\"transportId\":\"web-5\",\"sessionId\":\"sess-1\"}]" : "[]"
                        try await reply(CastMessage.nsReceiver,
                                        "{\"type\":\"RECEIVER_STATUS\",\"requestId\":\(rid),\"status\":{\"applications\":\(apps),\"volume\":{\"level\":0.4,\"muted\":false}}}")
                    case "LOAD":
                        lock.lock(); _loaded = json; lock.unlock()
                        try await reply(CastMessage.nsMedia,
                                        "{\"type\":\"MEDIA_STATUS\",\"requestId\":\(rid),\"status\":[{\"mediaSessionId\":1,\"playerState\":\"PLAYING\",\"currentTime\":12.5,\"media\":{\"duration\":600.0}}]}")
                    case "GET_STATUS":
                        try await reply(CastMessage.nsMedia,
                                        "{\"type\":\"MEDIA_STATUS\",\"requestId\":\(rid),\"status\":[{\"mediaSessionId\":1,\"playerState\":\"PAUSED\",\"currentTime\":20.0}]}")
                    default: break
                    }
                }
            } catch {}
        }

        func has(_ type: String) -> Bool { received.contains { $0["type"] as? String == type } }
        func find(_ type: String) -> [String: Any] { received.last { $0["type"] as? String == type }! }
        func stop() { server.stop() }
    }

    func testConnectsLoadsAndControls() async throws {
        try AppServices.initForTests()
        let identity = try LoopbackServer.selfSignedIdentity()
        let data = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let open: CastServer.Opener = { _, _ in DataByteSource(data) }
        let factory = CastMediaFactory(files: AppServices.mediaFileDao, catalog: AppServices.catalogDao, openRead: open,
                                       preferredSubtitleLanguage: { "" }, preferredAudioLanguage: { "en" })
        let store = TvLinkStore(url: AppPaths.stores.appendingPathComponent("tv_link.json"), secrets: AppServices.secrets)
        let cast = CastController(open: open, tvLink: TvLinkClient(store: store), progress: WatchProgressStore(), media: factory,
                                  autoPlayNext: { false })
        let fake = try FakeChromecast(identity: identity)
        defer { fake.stop() }

        try await cast.connect(CastDevice(id: "cc", name: "Living Room", kind: .chromecast, host: "127.0.0.1", port: fake.port))
        XCTAssertTrue(cast.state.connected, cast.state.error ?? "")
        XCTAssertEqual(cast.state.deviceName, "Living Room")

        let media = CastMedia(fileId: "/Users/me/Movies/Heat (1995).mp4", account: "device", fileName: "Heat (1995).mp4", title: "Heat",
                              subtitles: [CastSubtitle(id: "sub1", label: "English", language: "en", vtt: "WEBVTT\n\n")],
                              activeSubtitle: "sub1")
        await cast.load(media, startMs: 754_000)
        await waitFor(10_000) { fake.loaded != nil }
        let load = fake.loaded!
        XCTAssertEqual(load["sessionId"] as? String, "sess-1")
        XCTAssertEqual(load["currentTime"] as? Double, 754.0)
        let m = load["media"] as! [String: Any]
        XCTAssertEqual(m["contentType"] as? String, "video/mp4")
        XCTAssertEqual((load["activeTrackIds"] as? [Int])?.first, 1)
        let url = m["contentId"] as! String
        XCTAssertTrue(matches(url, "^http://127\\.0\\.0\\.1:[0-9]+/\(cast.server.token)/v\(CastFormats.javaHash(media.fileId))a0$"), url)

        // The receiver can fetch the video from the Mac.
        let (head, body) = try await rawHttp(url, range: "bytes=10-19")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 206"))
        XCTAssertEqual(body, data[10..<20])
        let track = (m["tracks"] as! [[String: Any]])[0]["trackContentId"] as! String
        let (_, vtt) = try await rawHttp(track)
        XCTAssertEqual(String(decoding: vtt, as: UTF8.self), "WEBVTT\n\n")

        // The LOAD reply arrives as MEDIA_STATUS: playing at 12.5 s of 600 s.
        await waitFor { cast.state.playing && cast.state.durationMs == 600_000 }
        XCTAssertEqual(cast.state.volume, 0.4)
        cast.pause()
        cast.seek(to: 30_000)
        cast.selectSubtitle(nil)
        await waitFor { fake.has("PAUSE") && fake.has("SEEK") && fake.has("EDIT_TRACKS_INFO") }
        let seek = fake.find("SEEK")
        XCTAssertEqual(seek["currentTime"] as? Double, 30.0)
        XCTAssertEqual(seek["mediaSessionId"] as? Int, 1)
        XCTAssertEqual((fake.find("EDIT_TRACKS_INFO")["activeTrackIds"] as? [Any])?.count, 0)

        let position = await cast.disconnect()
        XCTAssertFalse(cast.state.connected)
        XCTAssertTrue(position > 0)
        await waitFor { fake.has("STOP") }
        XCTAssertFalse(cast.server.running)
    }

    func testDevicesListVeltoretTvsFirstAndDiscoveryIsRefCounted() throws {
        try AppServices.initForTests()
        let open: CastServer.Opener = { _, _ in DataByteSource(Data()) }
        let factory = CastMediaFactory(files: AppServices.mediaFileDao, catalog: AppServices.catalogDao, openRead: open,
                                       preferredSubtitleLanguage: { "" }, preferredAudioLanguage: { "en" })
        let store = TvLinkStore(url: AppPaths.stores.appendingPathComponent("tv_link.json"), secrets: AppServices.secrets)
        let cast = CastController(open: open, tvLink: TvLinkClient(store: store), progress: WatchProgressStore(), media: factory,
                                  autoPlayNext: { false })
        cast.startDiscovery()
        cast.startDiscovery()
        cast.stopDiscovery()
        cast.stopDiscovery()
        cast.stopDiscovery() // extra stops are harmless
        XCTAssertTrue(cast.devices.isEmpty || cast.devices.first?.kind == .veltoret || !cast.devices.contains { $0.kind == .veltoret })
    }
}
