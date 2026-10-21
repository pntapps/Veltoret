import CryptoKit
import XCTest
import VeltoretKit
@testable import VeltoretCast

/// Port of the Windows TvLinkTest.
final class TvLinkTests: XCTestCase {
    private let secret = TvLinkProtocol.newSecret()
    private let body = Data("{\"type\":\"pause\"}".utf8)

    func testSignedRequestsVerify() {
        let time: Int64 = 1_000_000
        let signature = TvLinkProtocol.sign(secret: secret, method: "POST", path: "/command", time: time, body: body)
        XCTAssertEqual(signature.count, 44)
        XCTAssertTrue(TvLinkProtocol.verify(secret: secret, method: "POST", path: "/command", time: time, body: body, signature: signature, now: time + 1_000))
    }

    func testAnyChangeBreaksTheSignature() {
        let time: Int64 = 1_000_000
        let signature = TvLinkProtocol.sign(secret: secret, method: "POST", path: "/command", time: time, body: body)
        XCTAssertFalse(TvLinkProtocol.verify(secret: secret, method: "POST", path: "/play", time: time, body: body, signature: signature, now: time))
        XCTAssertFalse(TvLinkProtocol.verify(secret: secret, method: "POST", path: "/command", time: time + 1, body: body, signature: signature, now: time))
        XCTAssertFalse(TvLinkProtocol.verify(secret: secret, method: "POST", path: "/command", time: time, body: Data("{\"type\":\"stop\"}".utf8),
                                             signature: signature, now: time))
        XCTAssertFalse(TvLinkProtocol.verify(secret: TvLinkProtocol.newSecret(), method: "POST", path: "/command", time: time, body: body,
                                             signature: signature, now: time))
    }

    func testOldRequestsAreRefused() {
        let time: Int64 = 1_000_000
        let signature = TvLinkProtocol.sign(secret: secret, method: "POST", path: "/status", time: time, body: Data())
        XCTAssertFalse(TvLinkProtocol.verify(secret: secret, method: "POST", path: "/status", time: time, body: Data(), signature: signature,
                                             now: time + TvLinkProtocol.maxSkewMs + 1))
    }

    func testStreamUrls() {
        XCTAssertEqual(TvLinkProtocol.streamUrl("http://192.168.1.20:4000/abc/v1"), "vlink://192.168.1.20:4000/abc/v1")
        XCTAssertTrue(TvLinkProtocol.isStream("vlink://192.168.1.20:4000/abc/v1"))
        XCTAssertFalse(TvLinkProtocol.isStream("content://media/external/video/1"))
    }

    func testCanonicalStringIsExact() {
        // HMAC over "POST /command 1000000\n" + body, keyed with the decoded secret.
        let key = SymmetricKey(data: Data(base64Encoded: secret)!)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data("POST /command 1000000\n".utf8) + body, using: key)).base64EncodedString()
        XCTAssertEqual(TvLinkProtocol.sign(secret: secret, method: "POST", path: "/command", time: 1_000_000, body: body), expected)
    }

    func testJsonFollowsKotlinRules() throws {
        // Nulls aren't written; names are camelCase.
        XCTAssertEqual(LinkJson.string(LinkCommand(type: LinkCommand.pause)), "{\"type\":\"pause\"}")
        XCTAssertEqual(LinkJson.string(LinkCommand(type: LinkCommand.subtitle)), "{\"type\":\"subtitle\"}")
        XCTAssertEqual(LinkJson.string(LinkCommand(type: LinkCommand.seek, positionMs: 754000)), "{\"type\":\"seek\",\"positionMs\":754000}")
        // The TV leaves out defaults: {} is an idle TV.
        let idle = try LinkJson.decode(LinkStatus.self, "{}")
        XCTAssertFalse(idle.active)
        XCTAssertTrue(idle.audio.isEmpty)
        XCTAssertEqual(idle.source, "")
        XCTAssertTrue(try LinkJson.decode(LinkStatus.self, "{\"ended\":true,\"unknown\":5}").ended)
        let reply = try LinkJson.decode(LinkReply.self, "{\"ok\":true}")
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.message, "")
        XCTAssertNil(reply.code)
        let status = try LinkJson.decode(LinkStatus.self, "{\"active\":true,\"positionMs\":5,\"audio\":[{\"id\":\"a0\",\"label\":\"English\"}],\"audioSelected\":\"a0\"}")
        XCTAssertEqual(status.audio[0].id, "a0")
        XCTAssertEqual(status.audio[0].detail, "")
        let play = LinkJson.string(LinkPlay(title: "Heat", fileId: "smb://nas/h/Heat (1995).mkv", accountEmail: "smb://nas", startMs: 0))
        XCTAssertEqual(play, "{\"title\":\"Heat\",\"fileId\":\"smb://nas/h/Heat (1995).mkv\",\"accountEmail\":\"smb://nas\",\"startMs\":0}")
        // Escaping: quotes, backslashes and control characters; non-ASCII as is.
        XCTAssertEqual(LinkJson.string(LinkPairStart(phoneId: "a\"b\\c\n", phoneName: "Café")),
                       "{\"phoneId\":\"a\\\"b\\\\c\\n\",\"phoneName\":\"Café\"}")
    }

    func testStoreKeepsSecretsAndDeviceId() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let secrets = MemorySecretStore()
        let store = TvLinkStore(url: url, secrets: secrets)
        let id = store.deviceId
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(id, id.lowercased())
        store.save(LinkPeer(id: "tv1", name: "Living room"), secret: "c2VjcmV0")
        let again = TvLinkStore(url: url, secrets: secrets)
        XCTAssertEqual(again.deviceId, id)
        XCTAssertEqual(again.secret("tv1"), "c2VjcmV0")
        XCTAssertEqual(again.peers.count, 1)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("c2VjcmV0"))
        again.remove("tv1")
        XCTAssertNil(again.secret("tv1"))
        XCTAssertNil(secrets.get(TvLinkStore.secretKey("tv1")))
    }

    // ---- A fake TV (the Android TvLinkServer's rules) ---------------------------------------------

    final class FakeTv: @unchecked Sendable {
        let keys = PairingCrypto.newKeyPair()
        let salt = PairingCrypto.newSalt()
        let code = "123456"
        private let lock = NSLock()
        private var _secrets: [String: String] = [:]
        private var seen = Set<String>()
        private var _requests: [(path: String, body: String)] = []
        private var _playing = false
        var server: LoopbackServer!
        var port: Int { server.port }

        var secrets: [String: String] { lock.lock(); defer { lock.unlock() }; return _secrets }
        func clearSecrets() { lock.lock(); _secrets = [:]; lock.unlock() }
        var requests: [(path: String, body: String)] { lock.lock(); defer { lock.unlock() }; return _requests }
        var playing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _playing }
            set { lock.lock(); _playing = newValue; lock.unlock() }
        }

        init() throws {
            server = try LoopbackServer { [weak self] c in await self?.handle(c) }
        }

        private func handle(_ c: NetConnection) async {
            var head = Data()
            let marker = Data("\r\n\r\n".utf8)
            while head.range(of: marker) == nil {
                guard let chunk = try? await c.receive(max: 1), !chunk.isEmpty else { return }
                head.append(chunk)
            }
            let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ").map(String.init)
            var headers: [String: String] = [:]
            for l in lines.dropFirst() {
                if let i = l.firstIndex(of: ":") {
                    headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = length > 0 ? ((try? await c.receiveExactly(length)) ?? Data()) : Data()
            let (status, reply) = route(parts[0], parts[1], headers, body)
            let bytes = Data(reply.utf8)
            let resp = "HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            try? await c.send(Data(resp.utf8) + bytes)
        }

        private func route(_ method: String, _ path: String, _ headers: [String: String], _ body: Data) -> (String, String) {
            lock.lock(); _requests.append((path, String(decoding: body, as: UTF8.self))); lock.unlock()
            if method == "GET" && path == "/hello" {
                return ("200 OK", LinkJson.string(LinkHello(id: "tv-1", name: "Living room", version: 1, tvKey: PairingCrypto.encodeKey(keys),
                                                            salt: PairingCrypto.b64(salt))))
            }
            if path == "/pair/start" { return ("200 OK", "{\"ok\":true,\"message\":\"Enter the code shown on the TV\"}") }
            if path == "/pair" {
                guard let message = try? LinkJson.decode(PairMessage.self, String(decoding: body, as: UTF8.self)),
                      let phoneKey = Data(base64Encoded: message.phoneKey),
                      let key = try? PairingCrypto.sessionKey(keys, PairingCrypto.decodeKey(message.phoneKey), code: code, salt: salt),
                      let plain = PairingCrypto.open(key, .init(iv: message.iv, data: message.data), aad: phoneKey),
                      let s = try? LinkJson.decode(LinkPairSecret.self, String(decoding: plain, as: UTF8.self)) else {
                    return ("403 Forbidden", "{\"ok\":false,\"message\":\"That code didn't match. The TV now shows a new code; enter that one.\",\"code\":\"wrong_code\"}")
                }
                lock.lock(); _secrets[s.phoneId] = s.secret; lock.unlock()
                return ("200 OK", "{\"ok\":true,\"message\":\"Paired\"}")
            }
            // Signed endpoints.
            lock.lock()
            let ok: Bool = {
                guard let phone = headers["x-veltoret-phone"], let t = headers["x-veltoret-time"].flatMap({ Int64($0) }),
                      let sig = headers["x-veltoret-signature"], let sec = _secrets[phone],
                      TvLinkProtocol.verify(secret: sec, method: method, path: path, time: t, body: body, signature: sig, now: nowMillis()),
                      seen.insert(sig).inserted else { return false }
                return true
            }()
            let playing = _playing
            if ok && path == "/play" { _playing = true }
            lock.unlock()
            if !ok { return ("401 Unauthorized", "{\"ok\":false,\"message\":\"Pair this phone with the TV again\",\"code\":\"unpaired\"}") }
            switch path {
            case "/play": return ("200 OK", "{\"ok\":true,\"message\":\"phone\"}")
            case "/command": return ("200 OK", "{\"ok\":true}")
            case "/status":
                return ("200 OK", playing
                    ? "{\"active\":true,\"title\":\"Heat\",\"source\":\"phone\",\"playing\":true,\"positionMs\":5000,\"durationMs\":60000,\"audio\":[{\"id\":\"a0\",\"label\":\"English\"},{\"id\":\"a1\",\"label\":\"French\",\"detail\":\"AC3 · 5.1\"}],\"audioSelected\":\"a0\"}"
                    : "{}")
            default: return ("404 Not Found", "{\"ok\":false,\"message\":\"Not found\"}")
            }
        }

        func stop() { server.stop() }
    }

    func testPairsAndSignsLikeTheAndroidPhone() async throws {
        let tvServer = try FakeTv()
        defer { tvServer.stop() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TvLinkStore(url: url, secrets: MemorySecretStore())
        let client = TvLinkClient(store: store, phoneName: { "My Mac" })
        let hello = try await client.hello(host: "127.0.0.1", port: tvServer.port)
        let tv = LinkTv(id: hello.id, name: hello.name, host: "127.0.0.1", port: tvServer.port, paired: false)

        try await client.startPairing(tv)
        XCTAssertTrue(tvServer.requests.last!.body.contains("\"phoneName\":\"My Mac\""))

        do {
            try await client.pair(tv, code: "000000")
            XCTFail("A wrong code paired")
        } catch let e as LinkError {
            XCTAssertEqual(e.code, "wrong_code")
        }
        XCTAssertNil(store.secret("tv-1"))

        try await client.pair(tv, code: " 123456 ")
        XCTAssertNotNil(store.secret("tv-1"))
        XCTAssertEqual(store.secret("tv-1"), tvServer.secrets[store.deviceId])

        let source = try await client.play(tv, LinkPlay(title: "Heat", fileId: "x", accountEmail: "device"))
        XCTAssertEqual(source, "phone")
        tvServer.playing = false
        try await client.command(tv, LinkCommand(type: LinkCommand.pause))
        try await client.command(tv, LinkCommand(type: LinkCommand.pause)) // same body, fresh signature
        let status = try await client.status(tv)
        XCTAssertFalse(status.active)
        XCTAssertEqual(tvServer.requests.last!.body, "")

        // The TV forgot us: a 401 forgets the pairing here too.
        tvServer.clearSecrets()
        do {
            _ = try await client.status(tv)
            XCTFail("Expected unpaired")
        } catch let e as LinkError {
            XCTAssertEqual(e.code, "unpaired")
        }
        XCTAssertNil(store.secret("tv-1"))
    }

    func testUnreachableTvSaysSo() async throws {
        let store = TvLinkStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-test-\(UUID().uuidString).json"),
                                secrets: MemorySecretStore())
        let probe = try LoopbackServer { _ in }
        let port = probe.port
        probe.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            try await TvLinkClient(store: store).startPairing(LinkTv(id: "x", name: "Bedroom TV", host: "127.0.0.1", port: port, paired: false))
            XCTFail("Reached a closed port")
        } catch let e as LinkError {
            XCTAssertEqual(e.message, "Couldn't reach Bedroom TV. Check it's on and on the same Wi-Fi.")
        }
    }

    func testControllerPlaysOnTheTvAndTakesBackWhenItCloses() async throws {
        try AppServices.initForTests()
        let tvServer = try FakeTv()
        defer { tvServer.stop() }
        let store = TvLinkStore(url: AppPaths.stores.appendingPathComponent("tv_link.json"), secrets: AppServices.secrets)
        let client = TvLinkClient(store: store, phoneName: { "My Mac" })
        let open: CastServer.Opener = { _, _ in DataByteSource(Data(count: 100)) }
        let factory = CastMediaFactory(files: AppServices.mediaFileDao, catalog: AppServices.catalogDao, openRead: open,
                                       preferredSubtitleLanguage: { "" }, preferredAudioLanguage: { "en" })
        let cast = CastController(open: open, tvLink: client, progress: WatchProgressStore(), media: factory, autoPlayNext: { false })
        let tv = LinkTv(id: "tv-1", name: "Living room", host: "127.0.0.1", port: tvServer.port, paired: false)
        try await client.startPairing(tv)
        try await client.pair(tv, code: "123456")

        try await cast.connect(CastDevice(id: "tv-1", name: "Living room", kind: .veltoret, host: "127.0.0.1", port: tvServer.port, paired: true))
        XCTAssertTrue(cast.state.connected)
        XCTAssertNotNil(cast.state.link)
        await cast.load(CastMedia(fileId: "smb://nas/h/Heat (1995).mkv", account: "smb://nas", title: "Heat",
                                  subtitleLanguage: LinkPlay.subtitlesOff), startMs: 1_000)
        let play = tvServer.requests.last { $0.path == "/play" }!.body
        XCTAssertTrue(play.contains("\"fileId\":\"smb://nas/h/Heat (1995).mkv\""))
        XCTAssertTrue(play.contains("\"subtitleLanguage\":\"off\""))
        XCTAssertTrue(matches(play, "\"streamUrl\":\"vlink://127\\.0\\.0\\.1:[0-9]+/[0-9a-f]{32}/v[0-9]+\""), play)
        XCTAssertEqual(cast.state.linkSource, "phone")

        await waitFor(6_000) { cast.state.positionMs == 5000 }
        XCTAssertEqual(cast.state.linkAudio.count, 2)
        XCTAssertTrue(cast.state.playing)

        cast.selectLinkAudio("a1")
        await waitFor { tvServer.requests.contains { $0.path == "/command" && $0.body == "{\"type\":\"audio\",\"track\":\"a1\"}" } }

        // Back on the TV closes its player: the Mac takes over.
        tvServer.playing = false
        await waitFor(6_000) { !cast.state.connected }
        XCTAssertEqual(cast.state.positionMs, 5000)
        // Progress was saved for the file (no library entry: keyed by the file id); under 2 minutes left = watched.
        await waitFor { (try? AppServices.watchDao.get("file:smb://nas/h/Heat (1995).mkv"))??.watched == true }
    }
}
