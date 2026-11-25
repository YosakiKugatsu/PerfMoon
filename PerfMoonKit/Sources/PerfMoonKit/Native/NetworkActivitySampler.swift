// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import notify
import SystemConfiguration

/// Reads one link's 64-bit counters. Interface names, service order and available
/// links are cached separately so a VPN and its transport are never summed.
final class NetworkActivitySampler {
    private let store = SCDynamicStoreCreate(nil, "PerfMoon Network" as CFString, nil, nil)
    private var token: Int32 = -1
    private var nextDiscovery: TimeInterval = 0
    private var interfaces: [NetworkInterfaceInfo] = []
    private var primary: String?
    private var previous: (id: String, index: UInt32, counters: TransferCounters, uptime: TimeInterval)?

    init() {
        var registration: Int32 = -1
        if notify_register_check(kNotifySCNetworkChange, &registration) == NOTIFY_STATUS_OK {
            token = registration
        }
    }
    deinit { if token >= 0 { notify_cancel(token) } }

    func sample(preferred: String?, at time: TimeInterval) -> SampleOutcome {
        let uptime = ProcessInfo.processInfo.systemUptime
        var changed: Int32 = 0
        if token >= 0 { notify_check(token, &changed) }
        if changed != 0 || uptime >= nextDiscovery {
            guard discover() else { return .failed(.transient) }
            nextDiscovery = uptime + 30
        }
        guard let selected = interfaces.first(where: { $0.id == (preferred ?? primary) }) else {
            previous = nil
            return .network(NetworkActivity(interfaces: interfaces, rates: TransferRates(status: .unavailable(.interfaceDisconnected), source: .network)))
        }
        guard let counters = counters(for: selected) else {
            previous = nil
            nextDiscovery = 0
            // The interface may have disappeared since configuration discovery.
            return .network(NetworkActivity(interfaces: interfaces, selected: selected,
                                            rates: TransferRates(status: .unavailable(.retrying), source: .network)))
        }
        let old = previous.flatMap { $0.id == selected.id && $0.index == selected.index ? $0 : nil }
        let rates = counters.rates(since: old?.counters, elapsed: old.map { uptime - $0.uptime } ?? 0, at: time, source: .network)
        previous = (selected.id, selected.index, counters, uptime)
        return .network(NetworkActivity(interfaces: interfaces, selected: selected, rates: rates,
                                        receivedBytes: counters.incoming, sentBytes: counters.outgoing))
    }

    private func counters(for link: NetworkInterfaceInfo) -> TransferCounters? {
        // The routing table can return truncated byte counts even in RTM_IFINFO2.
        // Read the interface MIB directly and verify the index still names this link.
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(link.index), IFDATA_GENERAL]
        var info = ifmibdata()
        var size = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, 6, &info, &size, nil, 0) == 0, size == MemoryLayout<ifmibdata>.size else { return nil }
        let matches = withUnsafeBytes(of: info.ifmd_name) { $0.prefix { $0 != 0 }.elementsEqual(link.id.utf8) }
        guard matches else { return nil }
        return TransferCounters(incoming: info.ifmd_data.ifi_ibytes, outgoing: info.ifmd_data.ifi_obytes)
    }

    private func discover() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "Setup:/Network/Global/IPv4"]
        let patterns = ["Setup:/Network/Service/[^/]+/Interface", "State:/Network/Service/[^/]+/IPv[46]",
                        "State:/Network/Interface/[^/]+/Link"]
        let records = SCDynamicStoreCopyMultiple(store, keys as CFArray, patterns as CFArray) as? [String: [String: Any]] ?? [:]
        var hardware: [String: String] = [:]
        for (key, record) in records where key.hasSuffix("/Interface") {
            guard let device = record["DeviceName"] as? String,
                  let type = record["Type"] as? String, type == "Ethernet" || type == "IEEE80211",
                  !device.hasPrefix("bridge") else { continue }
            hardware[device] = record["UserDefinedName"] as? String ?? (type == "IEEE80211" ? "Wi-Fi" : "Ethernet")
        }
        var found: [NetworkInterfaceInfo] = []
        var cursor = list
        while let node = cursor {
            let link = node.pointee
            cursor = link.ifa_next
            guard link.ifa_flags & UInt32(IFF_UP) != 0, link.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = link.ifa_addr, address.pointee.sa_family == AF_LINK else { continue }
            let name = String(cString: link.ifa_name)
            // An unplugged port can still have IFF_UP and IFF_RUNNING. Tunnels may have no Link record.
            let state = records["State:/Network/Interface/\(name)/Link"]
            guard state?["Active"] as? Bool != false, state?["Detaching"] as? Bool != true else { continue }
            let index = if_nametoindex(link.ifa_name)
            guard index > 0 else { continue }
            let label = hardware[name] ?? Self.virtualName(name)
            found.append(NetworkInterfaceInfo(id: name, index: UInt32(index), name: label, isHardware: hardware[name] != nil))
        }
        interfaces = found.sorted { lhs, rhs in
            if lhs.isHardware != rhs.isHardware { return lhs.isHardware }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        let globals = keys.prefix(2).compactMap { records[$0]?["PrimaryInterface"] as? String }
        let order = records[keys[2]]?["ServiceOrder"] as? [String] ?? []
        // A VPN may own the default route. Resolve the first configured physical
        // service with a router, rather than counting the tunnel twice.
        var routed: [String] = []
        for service in order {
            for family in ["IPv4", "IPv6"] {
                let record = records["State:/Network/Service/\(service)/\(family)"]
                if record?["Router"] != nil, let name = record?["InterfaceName"] as? String { routed.append(name) }
            }
        }
        primary = Self.primaryInterface(interfaces: interfaces, globals: globals, routed: routed)
        return true
    }

    static func primaryInterface(interfaces: [NetworkInterfaceInfo], globals: [String], routed: [String]) -> String? {
        (globals + routed).first { candidate in interfaces.contains { $0.id == candidate && $0.isHardware } }
    }

    private static func virtualName(_ name: String) -> String {
        if name.hasPrefix("utun") { return "Tunnel" }
        if name.hasPrefix("bridge") { return "Bridge" }
        if name.hasPrefix("vmenet") { return "Virtual Ethernet" }
        if name.hasPrefix("awdl") { return "Wireless Direct Link" }
        return name
    }
}
