// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import IOKit
import PerfMoonNative

/// The first Apple sample establishes a baseline after waking the frozen
/// energy counters. Take subsequent deltas at frame boundaries, independent
/// of the phase of the UI timer. No subprocess is needed for aggregate power.
final class CorePowerSampler: @unchecked Sendable {
    private final class Subscription: @unchecked Sendable {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { pm_core_energy_close(handle) }
    }
    private let subscription: Subscription
    private let count: Int
    private let process = Process()
    private let lock = NSLock()
    private var last: (uptime: Double, time: Double, window: Double, watts: [Double])?
    private var delivered: Double = 0
    private var startedAt: Double = 0
    private(set) var usesCPURefresh = false
    private(set) var interval: Double = 0
    var pid: pid_t? { process.isRunning ? process.processIdentifier : nil }

    init?(topology: CPUTopology) {
        let locations = Self.locations(topology)
        guard !locations.isEmpty, let handle = pm_core_energy_open(locations, locations.count) else { return nil }
        subscription = Subscription(handle)
        count = locations.count
    }

    /// On this M5 Pro the smaller GPU report refreshes the same Energy Model
    /// bank as cpu_power. Fall back on machines where it does not advance.
    var refreshStalled: Bool {
        guard interval > 0 else { return false }
        let fresh = lock.withLock { last?.uptime } ?? startedAt
        return !process.isRunning || ProcessInfo.processInfo.systemUptime - fresh > 3.5 * interval + 0.5
    }

    func start(useCPURefresh: Bool) -> Bool {
        guard geteuid() == 0 else { return false }
        usesCPURefresh = useCPURefresh
        startedAt = ProcessInfo.processInfo.systemUptime
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = ["-s", useCPURefresh ? "cpu_power" : "gpu_power", "-i", "0", "-b", "1", "-f", "text"]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread { [weak self, subscription, count] in
            // The report header follows this sample's hardware read. Retain
            // only a possible partial marker across arbitrarily split pipe reads.
            let marker = Data("*** Sampled system activity (".utf8)
            var tail = Data()
            var readings = [Double](repeating: .nan, count: count)
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(reader.fileDescriptor, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                tail.append(contentsOf: buffer.prefix(n))
                if let range = tail.range(of: marker) {
                    var window = 0.0
                    let valid = pm_core_energy_read(subscription.handle, &readings, count, &window)
                    if valid, let self {
                        lock.withLock { last = (ProcessInfo.processInfo.systemUptime, Date.timeIntervalSinceReferenceDate, window, readings) }
                    }
                    tail.removeSubrange(tail.startIndex..<range.upperBound)
                }
                tail = Data(tail.suffix(marker.count - 1))
            }
        }
        return true
    }

    func stop() { if process.isRunning { process.terminate() } }
    deinit { stop() }

    func sample(interval: Double) -> SampleOutcome {
        self.interval = interval
        guard process.isRunning else { return .failed(.transient) }
        // One refresh per scheduled tick. Keep the same subscription across
        // foreground/background cadence changes; the pipe records the actual
        // end time. Never wait for Apple's sampler on the UI's IPC path.
        defer { _ = kill(process.processIdentifier, SIGINFO) }
        guard let frame = lock.withLock({ last }), frame.uptime > delivered else { return .noNewData }
        delivered = frame.uptime
        return .coreEnergy(watts: frame.watts.map { $0.isFinite ? $0 : nil }, measuredAt: frame.time, window: frame.window)
    }

    private static func locations(_ topology: CPUTopology) -> [PMCoreLocation] {
        guard !topology.cores.isEmpty else { return [] }
        let node = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard node != 0 else { return [] }
        defer { IOObjectRelease(node) }
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(node, kIODeviceTreePlane, &children) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(children) }
        var slots = [PMCoreLocation](repeating: PMCoreLocation(), count: topology.cores.count)
        var seen = Set<String>()
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            func property(_ name: String) -> Any? {
                IORegistryEntryCreateCFProperty(child, name as CFString, nil, 0)?.takeRetainedValue()
            }
            func word(_ key: String) -> UInt32? {
                guard let data = property(key) as? Data, data.count == 4 else { return nil }
                return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            }
            guard let logical = property("logical-cpu-id") as? NSNumber,
                  let core = topology.cores.first(where: { $0.machIndex == logical.intValue }),
                  let tag = (property("cluster-type") as? Data)?.first, [69, 77, 80].contains(tag),
                  let cluster = word("cluster-id"), let slot = word("cluster-core-id") else { continue }
            guard seen.insert("\(tag)/\(cluster)/\(slot)").inserted else { return [] }
            slots[core.flatIndex] = PMCoreLocation(tier: tag, cluster: cluster, slot: slot)
        }
        return slots.allSatisfy { $0.tier != 0 } ? slots : []
    }
}
