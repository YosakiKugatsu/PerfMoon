// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// This entry point has no GUI, preferences or arbitrary file/command requests.
/// EOF from the owning GUI releases every sampler and exits the privileged worker.
@MainActor
public enum CollectorServer {
    public static func run(socketPath: String) async {
        guard geteuid() == 0, let socket = try? CollectorSocket(),
              (try? socket.address(socketPath, bindSocket: false)) != nil else { return }
        var peer: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket.fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0, peer > 0 else { return }
        let native = NativeMetricProvider()
        var overhead = CollectorOverhead()
        var diagnostics = CollectorOverhead()
        var publishedInterfaces: [NetworkInterfaceInfo]?
        var busyDisk = false
        let healthQueue = DispatchQueue(label: "PerfMoon.drive-health", qos: .utility)
        var busyProcesses = false
        var sensorKeys = Set(native.sensors.map(\.id))
        while let request = await Task.detached(operation: { try? socket.read(CollectorRequest.self) }).value {
            let id = request.id
            var reply = CollectorReply(id: id)
            switch request.command {
            case .identify:
                reply.uid = geteuid()
                reply.machine = native.machine
                reply.sensors = native.sensors
            case .open(let source, let time):
                reply.opened = native.open(source, at: time)
                if source == .sensors {
                    sensorKeys = Set(native.sensors.map(\.id))
                    reply.sensors = native.sensors
                }
            case .close(let source):
                if source == .network { publishedInterfaces = nil }
                native.close(source)
            case .baseline(let source, let time):
                native.rebaseline(source, at: time)
            case .volumesChanged:
                native.invalidateDiskDevices()
            case .diskHealth(let device):
                healthQueue.async {
                    let report = StartupVolumes.health(for: device)
                    try? socket.write(CollectorReply(id: id, diskHealth: report))
                }
                continue
            case .overhead(let time, let window, let diagnostic):
                let pids = [peer, getpid()] + native.powerSamplerPIDs
                reply.usage = diagnostic ? diagnostics.sample(pids: pids, at: time, window: window)
                                         : overhead.sample(pids: pids, at: time, window: window)
            case .sample(let batch, let time):
                var outcomes: [JobID: SampleOutcome] = [:]
                // Thermal evidence uses the same tick's energy and GPU reads.
                for job in JobID.allCases {
                    guard var request = batch[job] else { continue }
                    if !request.sensorIDs.isEmpty { request.sensorIDs = request.sensorIDs.filter(sensorKeys.contains) }
                    let outcome = native.sample(job, request: request, at: time)
                    if case .network(var network) = outcome {
                        if network.interfaces != publishedInterfaces {
                            publishedInterfaces = network.interfaces
                            reply.networkInterfaces = network.interfaces
                        }
                        network.interfaces = []
                        outcomes[job] = .network(network)
                    } else {
                        outcomes[job] = outcome
                    }
                }
                reply.outcomes = outcomes
                if batch[.thermal] != nil {
                    reply.cpuThrottle = native.throttleStatus
                    reply.gpuThrottle = native.gpuThrottleStatus
                }
            case .disks(let time):
                if !busyDisk, let collect = native.diskBackgroundSample {
                    busyDisk = true
                    Task {
                        let outcome = await Task.detached(priority: .utility) { collect(time) }.value
                        busyDisk = false
                        try? socket.write(CollectorReply(id: id, outcomes: [.disk: outcome]))
                    }
                    continue
                }
                reply.outcomes = [.disk: .noNewData]
            case .processes(let time, let rates):
                if !busyProcesses, let collect = native.processBackgroundSample {
                    busyProcesses = true
                    Task(priority: .utility) {
                        let snapshot = await collect(time, rates)
                        busyProcesses = false
                        try? socket.write(CollectorReply(id: id, processes: snapshot))
                    }
                    continue
                }
                reply.processes = ProcessMemorySnapshot()
            }
            guard (try? socket.write(reply)) != nil else { break }
        }
        for source in SourceID.allCases { native.close(source) }
    }
}

private struct CollectorOverhead {
    private var last = [pid_t: UInt64]()
    private var previousTime: UInt64?
    mutating func sample(pids: [pid_t], at time: Double, window: Double) -> SelfUsage {
        let now = mach_absolute_time()
        var current: [pid_t: UInt64] = [:]
        var totalBytes: Double = 0, delta: Double = 0
        for pid in pids {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else { continue }
            totalBytes += Double(info.ri_phys_footprint)
            let ticks = info.ri_user_time + info.ri_system_time
            if let old = last[pid], ticks >= old { delta += Double(ticks - old) }
            current[pid] = ticks
        }
        var usage = SelfUsage.pending
        if let previousTime, now > previousTime, !current.isEmpty {
            var base = mach_timebase_info_data_t()
            mach_timebase_info(&base)
            let seconds = Double(now - previousTime) * Double(base.numer) / Double(base.denom) / 1e9
            if seconds <= window * 1.5 {
                usage.cpu = MetricReading(value: delta * 100 / Double(now - previousTime), unit: .percent,
                                          status: .valid, timestamp: time, window: seconds)
            }
        }
        if !current.isEmpty {
            usage.footprint = MetricReading(value: totalBytes, unit: .bytes, status: .valid, timestamp: time)
        }
        last = current
        previousTime = now
        return usage
    }
}
