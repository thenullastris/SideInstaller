import Foundation
import Darwin

/// Best-effort detection of the LocalDevVPN loopback + Wi-Fi by scanning the
/// active network interfaces. LocalDevVPN brings up a `utun*` tunnel interface;
/// Wi-Fi is `en0`. This is a quick readout — the real proof is whether the
/// lockdown connection succeeds.
enum NetworkStatus {

    struct Interface {
        let name: String
        let ipv4: String
    }

    static func interfaces() -> [Interface] {
        var result: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: cur.pointee.ifa_name)

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
            guard r == 0 else { continue }
            result.append(Interface(name: name, ipv4: String(cString: host)))
        }
        return result
    }

    /// (vpnUp, wifiUp, detail) — vpnUp if a utun/ipsec/tap interface has an IP.
    static func summarize() -> (vpn: Bool, wifi: Bool, detail: String) {
        let ifs = interfaces()
        let vpn = ifs.contains { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") || $0.name.hasPrefix("tap") || $0.name.hasPrefix("ppp") }
        let wifi = ifs.contains { $0.name == "en0" }
        let detail = ifs.map { "\($0.name)=\($0.ipv4)" }.joined(separator: ", ")
        return (vpn, wifi, detail)
    }
}
