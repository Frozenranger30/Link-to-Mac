import Foundation

enum NetworkInfo {
    /// IPv4 addresses of active, non-loopback interfaces; Wi-Fi/Ethernet (en*) first.
    static func ipv4Addresses() -> [String] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: p.pointee.ifa_name)
                    result.append((name, String(cString: host)))
                }
            }
            ptr = p.pointee.ifa_next
        }
        let sorted = result.sorted { a, b in
            let ae = a.0.hasPrefix("en"), be = b.0.hasPrefix("en")
            if ae != be { return ae }
            return a.0 < b.0
        }
        var seen = Set<String>()
        return sorted.map(\.1).filter { seen.insert($0).inserted && !$0.hasPrefix("169.254.") }
    }

    static var computerName: String {
        Host.current().localizedName ?? "Mac"
    }
}
