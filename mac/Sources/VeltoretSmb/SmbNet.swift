import Darwin
import Foundation

/// Small blocking BSD-socket helpers (run them off the main thread / cooperative pool via `SmbNet.background`).
enum SmbNet {
    /// Runs blocking work on a GCD thread so Swift concurrency's cooperative threads aren't held.
    static func background<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(with: Result { try work() })
            }
        }
    }

    /// IPv4 address (host byte order) of a dotted string, nil when it isn't one.
    static func parseIPv4(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    static func format(_ ip: UInt32) -> String {
        "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
    }

    /// Resolves a host name (or literal) to socket addresses, IPv4 first. Throws `SmbSocketError.hostNotFound`.
    static func resolve(_ host: String, port: Int) throws -> [Data] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { throw SmbSocketError.hostNotFound(host) }
        defer { freeaddrinfo(first) }
        var v4: [Data] = [], v6: [Data] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if let sa = ai.pointee.ai_addr {
                let d = Data(bytes: sa, count: Int(ai.pointee.ai_addrlen))
                if ai.pointee.ai_family == AF_INET { v4.append(d) } else if ai.pointee.ai_family == AF_INET6 { v6.append(d) }
            }
            p = ai.pointee.ai_next
        }
        let all = v4 + v6
        if all.isEmpty { throw SmbSocketError.hostNotFound(host) }
        return all
    }

    /// A quick TCP connect to `host:port`, so "server off" fails fast (libsmb2 would wait for the OS timeout).
    static func probe(host: String, port: Int, timeoutMs: Int32) throws {
        let addrs = try resolve(host, port: port)
        var lastError: SmbSocketError = .timedOut
        for addr in addrs.prefix(2) {
            switch connectOnce(addr, timeoutMs: timeoutMs) {
            case 0: return
            case ECONNREFUSED: lastError = .refused
            case ETIMEDOUT: lastError = .timedOut
            case let e: lastError = .unreachable(e)
            }
        }
        throw lastError
    }

    /// 0 on success, else an errno (ETIMEDOUT when no answer in time).
    private static func connectOnce(_ addr: Data, timeoutMs: Int32) -> Int32 {
        let family = addr.withUnsafeBytes { $0.load(fromByteOffset: 1, as: UInt8.self) }
        let fd = socket(Int32(family), SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { return errno }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = addr.withUnsafeBytes { raw -> Int32 in
            Darwin.connect(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(addr.count))
        }
        if rc == 0 { return 0 }
        if errno != EINPROGRESS { return errno }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let n = poll(&pfd, 1, timeoutMs)
        if n <= 0 { return ETIMEDOUT }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err
    }

    /// Which of `hosts` accept TCP on `port`, probing them all at once with one poll (discovery sweep).
    static func acceptingHosts(_ hosts: [UInt32], port: UInt16, timeoutMs: Int32) -> [UInt32] {
        var pending: [(fd: Int32, ip: UInt32)] = []
        var found: [UInt32] = []
        for ip in hosts {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            if fd < 0 { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = port.bigEndian
            sa.sin_addr = in_addr(s_addr: ip.bigEndian)
            let rc = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if rc == 0 { found.append(ip); close(fd); continue }
            if errno != EINPROGRESS { close(fd); continue }
            pending.append((fd, ip))
        }
        defer { for p in pending { close(p.fd) } }
        var pfds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var done = Set<Int32>()
        while done.count < pfds.count {
            let left = Int32(deadline.timeIntervalSinceNow * 1000)
            if left <= 0 { break }
            let n = poll(&pfds, nfds_t(pfds.count), left)
            if n <= 0 { break }
            for i in pfds.indices where pfds[i].revents != 0 && !done.contains(pfds[i].fd) {
                done.insert(pfds[i].fd)
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(pfds[i].fd, SOL_SOCKET, SO_ERROR, &err, &len)
                if err == 0 { found.append(pending[i].ip) }
                pfds[i].fd = -1 // poll ignores negative fds
            }
        }
        return found
    }

    /// Sends a NetBIOS node status query to `ip` and reads its name (nil when it doesn't answer in time).
    static func netBiosName(_ ip: UInt32, timeoutMs: Int32) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { return nil }
        defer { close(fd) }
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = NetBios.port.bigEndian
        sa.sin_addr = in_addr(s_addr: ip.bigEndian)
        let query = NetBios.nodeStatusQuery(Int(DispatchTime.now().uptimeNanoseconds & 0x7FFF))
        let sent = query.withUnsafeBytes { buf in
            withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n <= 0 { return nil }
        return NetBios.parseNodeStatus(buffer, length: n)
    }

    // MARK: - Local network

    struct LocalNetwork: Equatable {
        var ownAddress: UInt32
        var prefix: Int
        var gateway: String?
    }

    private static let skippedInterfacePrefixes = ["lo", "utun", "awdl", "llw", "bridge", "vmnet", "gif", "stf", "anpi", "ap", "ipsec", "ppp", "vnic"]

    /// The Wi-Fi or Ethernet network's IPv4 address and gateway; nil with no such network.
    static func localNetwork() -> LocalNetwork? {
        let route = defaultRoute()
        var candidates: [(name: String, net: LocalNetwork)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(first) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.pointee.ifa_netmask else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if skippedInterfacePrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if (ip >> 16) == 0xA9FE { continue } // 169.254 link-local
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let gateway = route?.interface == name ? route?.gateway : nil
            candidates.append((name, LocalNetwork(ownAddress: ip, prefix: m.nonzeroBitCount, gateway: gateway)))
        }
        // The interface with the default route is the one the Mac actually uses.
        if let r = route, let c = candidates.first(where: { $0.name == r.interface }) { return c.net }
        return candidates.first(where: { $0.name.hasPrefix("en") })?.net ?? candidates.first?.net
    }

    /// The IPv4 default gateway and its interface, from the routing table.
    private static func defaultRoute() -> (gateway: String, interface: String)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buf, &size, nil, 0) == 0 else { return nil }
        return buf.withUnsafeBytes { raw -> (String, String)? in
            var offset = 0
            let headerSize = MemoryLayout<rt_msghdr>.size
            while offset + headerSize <= size {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let msgLen = Int(hdr.rtm_msglen)
                if msgLen <= 0 { break }
                defer { offset += msgLen }
                var sa = offset + headerSize
                var dst: UInt32?
                var gw: UInt32?
                for bit in 0..<Int(RTAX_MAX) {
                    guard (hdr.rtm_addrs & (1 << bit)) != 0 else { continue }
                    guard sa + 2 <= offset + msgLen else { break }
                    let len = Int(raw[sa])
                    let family = raw[sa + 1]
                    if family == UInt8(AF_INET), len >= 8 {
                        let a = UInt32(raw[sa + 4]) << 24 | UInt32(raw[sa + 5]) << 16 | UInt32(raw[sa + 6]) << 8 | UInt32(raw[sa + 7])
                        if bit == Int(RTAX_DST) { dst = a } else if bit == Int(RTAX_GATEWAY) { gw = a }
                    } else if bit == Int(RTAX_DST), family == 0 || len == 0 {
                        dst = 0
                    }
                    let step = len == 0 ? 4 : (len + 3) & ~3
                    sa += step
                }
                if dst == 0, let g = gw, g != 0 {
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    guard if_indextoname(UInt32(hdr.rtm_index), &name) != nil else { continue }
                    return (format(g), String(cString: name))
                }
            }
            return nil
        }
    }
}
