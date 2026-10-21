import XCTest
@testable import VeltoretSmb

/// Port of Windows SmbDiscoveryTest.
final class SmbDiscoveryTests: XCTestCase {
    private func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { (a << 24) | (b << 16) | (c << 8) | d }

    func testSweepsTheSubnetWithoutNetworkAndBroadcast() {
        let hosts = SmbDiscovery.subnetHosts(ip(192, 168, 0, 57), 24)
        XCTAssertEqual(254, hosts.count)
        XCTAssertEqual("192.168.0.1", SmbDiscovery.fromInt(hosts.first!))
        XCTAssertEqual("192.168.0.254", SmbDiscovery.fromInt(hosts.last!))
    }

    func testHugeNetworksFallBackToTheNearby254() {
        let hosts = SmbDiscovery.subnetHosts(ip(10, 1, 2, 3), 8)
        XCTAssertEqual(254, hosts.count)
        XCTAssertEqual("10.1.2.1", SmbDiscovery.fromInt(hosts.first!))
        XCTAssertEqual(1022, SmbDiscovery.subnetHosts(ip(10, 1, 2, 3), 22).count)
    }

    func testIntConversionRoundTrips() {
        XCTAssertEqual(ip(192, 168, 1, 200), SmbDiscovery.toInt("192.168.1.200"))
        XCTAssertEqual("192.168.1.200", SmbDiscovery.fromInt(ip(192, 168, 1, 200)))
    }

    func testQueryAsksForTheWildcardName() {
        let q = NetBios.nodeStatusQuery(0x1234)
        XCTAssertEqual(50, q.count)
        XCTAssertEqual(0x12, q[0])
        XCTAssertEqual(32, q[12])
        XCTAssertEqual("CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", String(decoding: q[13..<45], as: UTF8.self))
        XCTAssertEqual(0x21, q[47])
    }

    /// A node status answer listing `names` as (name, suffix, group).
    private func answer(_ names: [(String, UInt8, Bool)]) -> [UInt8] {
        var o = [UInt8](repeating: 0, count: 12)
        o.append(32)
        o += [UInt8](repeating: UInt8(ascii: "A"), count: 32)
        o.append(0)
        o += [0, 0x21, 0, 1, 0, 0, 0, 0, 0, 0] // type, class, TTL, length
        o.append(UInt8(names.count))
        for (name, suffix, group) in names {
            o += Array(name.padding(toLength: 15, withPad: " ", startingAt: 0).utf8)
            o.append(suffix)
            o.append(group ? 0x80 : 0x04)
            o.append(0)
        }
        return o
    }

    func testReadsTheFileServerName() {
        let reply = answer([("WORKGROUP", 0x00, true), ("ROUTER-AX", 0x00, false), ("ROUTER-AX", 0x20, false)])
        XCTAssertEqual("ROUTER-AX", NetBios.parseNodeStatus(reply))
    }

    func testFallsBackToTheWorkstationNameAndIgnoresGroups() {
        XCTAssertEqual("NAS", NetBios.parseNodeStatus(answer([("HOME", 0x20, true), ("NAS", 0x00, false)])))
        XCTAssertNil(NetBios.parseNodeStatus(answer([("WORKGROUP", 0x00, true)])))
        XCTAssertNil(NetBios.parseNodeStatus([UInt8](repeating: 0, count: 5)))
    }

    func testEntriesPastTheReceivedLengthAreSkipped() {
        let reply = answer([("NAS", 0x00, false), ("NAS", 0x20, false)])
        // Cut the second entry off: only the first (workstation) name is readable.
        XCTAssertEqual("NAS", NetBios.parseNodeStatus(reply, length: reply.count - 18))
    }

    // Mac additions: merging rules from the spec (AddServerViewModel.scan).

    func testMergeDedupesByAddressAndSorts() {
        var list: [FoundServer] = []
        list = SmbDiscovery.merge(list, FoundServer(address: "192.168.0.20", name: nil))
        list = SmbDiscovery.merge(list, FoundServer(address: "192.168.0.10", name: "NAS"))
        list = SmbDiscovery.merge(list, FoundServer(address: "192.168.0.1", name: nil, isRouter: true))
        list = SmbDiscovery.merge(list, FoundServer(address: "192.168.0.20", name: "PC"))
        list = SmbDiscovery.merge(list, FoundServer(address: "192.168.0.10", name: "Other"))
        XCTAssertEqual(["192.168.0.1", "192.168.0.10", "192.168.0.20"], list.map(\.address))
        XCTAssertEqual("NAS", list[1].name)
        XCTAssertEqual("PC", list[2].name)
        XCTAssertEqual("Your router", list[0].label)
        XCTAssertEqual("192.168.0.1 · router", list[0].subtitle)
        XCTAssertEqual("File server", FoundServer(address: "x", name: nil).label)
    }
}
