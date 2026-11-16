// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// PerfMoon's own CPU time and physical footprint. This reads only the current process.
public struct SelfUsage: Sendable, Equatable {
    /// Share of one core over the last sampling window.
    public var cpu: MetricReading
    public var footprint: MetricReading

    public static let pending = SelfUsage(cpu: .pending(.percent), footprint: .pending(.bytes))
}

public struct SelfUsageSampler: Sendable {
    private var lastCPUTime: TimeInterval?
    private var lastWallTime: TimeInterval?

    public init() {}

    public mutating func reset() {
        lastCPUTime = nil
        lastWallTime = nil
    }

    public mutating func sample(at now: TimeInterval, window: TimeInterval) -> SelfUsage {
        var result = SelfUsage.pending

        if let footprint = Self.physicalFootprint() {
            result.footprint = MetricReading(value: footprint, unit: .bytes, status: .valid, timestamp: now, window: 0)
        }

        if let cpuTime = Self.processCPUTime() {
            if let lastCPUTime, let lastWallTime, now > lastWallTime {
                let share = max(0, (cpuTime - lastCPUTime) / (now - lastWallTime) * 100)
                result.cpu = MetricReading(value: share, unit: .percent, status: .valid, timestamp: now, window: window)
            }
            lastCPUTime = cpuTime
            lastWallTime = now
        }
        return result
    }

    static func processCPUTime() -> TimeInterval? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    static func physicalFootprint() -> Double? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        return Double(info.ri_phys_footprint)
    }
}
