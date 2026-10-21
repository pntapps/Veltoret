import Foundation
import XCTest
@testable import VeltoretDrive

final class LoopbackReceiverTests: XCTestCase {
    func testReceivesTheRedirectAndIgnoresOtherRequests() async throws {
        let receiver = try LoopbackReceiver()
        defer { receiver.close() }
        XCTAssertTrue(receiver.redirectUri.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(receiver.redirectUri.hasSuffix("/"))
        let wait = Task {
            try await receiver.waitForRedirect { _ in
                LoopbackReceiver.page("Veltoret is connected", "You can close this tab and go back to the app.")
            }
        }

        let session = URLSession(configuration: .ephemeral)
        let (_, favicon) = try await session.data(from: URL(string: receiver.redirectUri + "favicon.ico")!)
        XCTAssertEqual((favicon as? HTTPURLResponse)?.statusCode, 404)
        let (page, _) = try await session.data(from: URL(string: receiver.redirectUri +
            "?state=s%2Bt&code=4%2F0Ab_x&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive")!)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Veltoret is connected"))

        let query = try await wait.value
        XCTAssertEqual(query["code"], "4/0Ab_x")
        XCTAssertEqual(query["state"], "s+t")
        XCTAssertEqual(query["scope"], "https://www.googleapis.com/auth/drive")
    }

    func testCancellingStopsWaiting() async throws {
        let receiver = try LoopbackReceiver()
        defer { receiver.close() }
        let wait = Task { try await receiver.waitForRedirect { _ in "" } }
        wait.cancel()
        do {
            _ = try await wait.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPageEscapesHtml() {
        XCTAssertTrue(LoopbackReceiver.page("<b>", "a & b").contains("&lt;b&gt;"))
        XCTAssertTrue(LoopbackReceiver.page("t", "a & b").contains("a &amp; b"))
    }
}
