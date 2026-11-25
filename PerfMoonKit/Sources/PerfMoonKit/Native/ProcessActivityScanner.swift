// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

struct ProcessCounters {
    let start: UInt64
    let cpu: UInt64
    let read: UInt64
    let written: UInt64

    func applyRates(to entry: inout ProcessMemoryEntry, since old: Self?, ticks: Double, seconds: Double) {
        guard let old, start == old.start, ticks > 0, seconds > 0 else { return }
        // rusage CPU time and mach_absolute_time use the same Mach ticks.
        if cpu >= old.cpu { entry.cpuPercent = Double(cpu - old.cpu) / ticks * 100 }
        if read >= old.read { entry.readBytesPerSecond = Double(read - old.read) / seconds }
        if written >= old.written { entry.writeBytesPerSecond = Double(written - old.written) / seconds }
    }
}

/// One scan serves all visible rankings. Resolve names only for the retained rows.
actor ProcessActivityScanner {
    private var pids: [Int32] = []
    private var previous: [Int32: ProcessCounters] = [:]
    private var lastTime: UInt64?
    private var names: [Int32: (start: UInt64, name: String)] = [:]
    private let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    func sample(at time: TimeInterval, includeRates: Bool) -> ProcessMemorySnapshot {
        // libproc's count-only call already includes slack. Retry a full buffer
        // once for processes that appeared between sizing and enumeration.
        if pids.isEmpty { pids = Array(repeating: 0, count: max(256, Int(proc_listallpids(nil, 0)) + 64)) }
        var count = listPIDs()
        if count == pids.count {
            pids.append(contentsOf: repeatElement(0, count: max(64, pids.count / 4)))
            count = listPIDs()
        }
        guard count > 0 else { return ProcessMemorySnapshot(status: .unavailable(.retrying)) }

        let now = mach_absolute_time()
        let ticks = lastTime.map { now > $0 ? Double(now - $0) : 0 } ?? 0
        let seconds = ticks * secondsPerTick
        var next: [Int32: ProcessCounters] = [:]
        if includeRates { next.reserveCapacity(count) }
        var memory = TopProcesses(), cpu = TopProcesses(), reads = TopProcesses(), writes = TopProcesses()
        var denied = 0
        for pid in pids.prefix(count) where pid > 0 {
            if Task.isCancelled { return ProcessMemorySnapshot() }
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else {
                if errno == EPERM || errno == EACCES { denied += 1 }
                continue
            }
            let start = info.ri_proc_start_abstime
            var row = ProcessMemoryEntry(pid: pid, name: "", memoryBytes: Double(info.ri_phys_footprint))
            if includeRates {
                let counters = ProcessCounters(start: start, cpu: info.ri_user_time + info.ri_system_time,
                                               read: info.ri_diskio_bytesread, written: info.ri_diskio_byteswritten)
                counters.applyRates(to: &row, since: previous[pid], ticks: ticks, seconds: seconds)
                next[pid] = counters
                cpu.insert(row, start: start, value: row.cpuPercent)
                reads.insert(row, start: start, value: row.readBytesPerSecond)
                writes.insert(row, start: start, value: row.writeBytesPerSecond)
            }
            memory.insert(row, start: start, value: row.memoryBytes)
        }
        previous = next
        lastTime = includeRates ? now : nil

        var usedNames: [Int32: (start: UInt64, name: String)] = [:]
        func named(_ top: TopProcesses) -> [ProcessMemoryEntry] {
            top.rows.map { item in
                var row = item.entry
                if let cached = usedNames[row.pid] ?? names[row.pid], cached.start == item.start {
                    row.name = cached.name
                } else {
                    row.name = Self.name(of: row.pid)
                }
                usedNames[row.pid] = (item.start, row.name)
                return row
            }
        }
        var snapshot = ProcessMemorySnapshot(entries: named(memory), status: .valid, timestamp: time, inaccessibleProcessCount: denied)
        snapshot.byCPU = named(cpu)
        snapshot.byRead = named(reads)
        snapshot.byWrite = named(writes)
        snapshot.rateWindow = includeRates && seconds > 0 ? seconds : nil
        names = usedNames
        return snapshot
    }

    private func listPIDs() -> Int {
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return min(Int(count), pids.count)
    }

    private static func name(of pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            return (String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) as NSString).lastPathComponent
        }
        if proc_name(pid, &path, UInt32(path.count)) > 0 {
            return String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        return "Process \(pid)"
    }
}

/// At most ten candidates per list, with a constant-time rejection for lower ranks.
private struct TopProcesses {
    struct Row {
        let entry: ProcessMemoryEntry
        let start: UInt64
        let value: Double
    }

    private(set) var rows: [Row] = []

    mutating func insert(_ entry: ProcessMemoryEntry, start: UInt64, value: Double) {
        guard value > 0 else { return }
        if rows.count == 10, let last = rows.last {
            guard value > last.value || (value == last.value && entry.pid < last.entry.pid) else { return }
            rows.removeLast()
        }
        let index = rows.firstIndex { value > $0.value || (value == $0.value && entry.pid < $0.entry.pid) } ?? rows.endIndex
        rows.insert(Row(entry: entry, start: start, value: value), at: index)
    }
}
