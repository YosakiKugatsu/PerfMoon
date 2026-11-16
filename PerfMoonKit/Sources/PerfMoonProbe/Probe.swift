// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import PerfMoonKit

/// Development-only command-line harness. Exercises the production collectors without
/// any UI, so collection cost and hardware readings can be independently compared.
@main
struct PerfMoonProbe {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        if args.contains("--benchmark-history") {
            benchmarkHistory()
            return
        }
        func option(_ name: String, fallback: String) -> String {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return fallback }
            return args[index + 1]
        }
        let duration = max(1, Double(option("--seconds", fallback: "30")) ?? 30)
        let interval = Double(option("--interval", fallback: "1")) ?? 1
        let mode = option("--mode", fallback: "overview")
        let native = NativeMetricProvider(recordTimings: true)
        let engine = MonitorEngine(fixtures: FixtureProvider(), liveProvider: native)
        engine.start(scenario: .typical, interval: UpdateInterval(rawValue: interval) ?? .one, temperatureSource: .cpuMax)
        if mode == "sensors" { engine.setDemand(.sensorTable, active: true) }
        else if let page = Page(rawValue: mode) {
            engine.setDemand(.window(page), active: true)
            engine.setDemand(.coreHistory, active: true)
        }
        if args.contains("--core-history") { engine.setDemand(.coreHistory, active: true) }
        if mode == "processes" { engine.setDemand(.memoryProcesses, active: true) }
        let topology = native.machine.cpuTopology
        emit(["type": "configuration", "chip": native.machine.chipName,
              "memoryBytes": native.machine.physicalMemory, "gpuCores": native.machine.gpuCoreCount,
              "logicalCPUs": topology.logicalCPUCount,
              "cpuClusters": topology.clusters.map { ["title": $0.title, "count": $0.count] },
              "sensors": native.sensors.count, "mode": mode, "interval": interval])
        if args.contains("--exercise") {
            try await exercise(engine)
            return
        }
        let began = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - began < duration {
            try await Task.sleep(for: .seconds(1))
            let s = engine.snapshot
            var metrics: [String: Any] = [:]
            func put(_ name: String, _ reading: MetricReading) {
                if let value = reading.value { metrics[name] = value }
            }
            put("cpuPercent", s.cpu.total); put("ePercent", s.cpu.eCore); put("sPercent", s.cpu.sCore); put("pPercent", s.cpu.pCore)
            put("eGHz", s.cpu.eFrequency); put("sGHz", s.cpu.sFrequency); put("pGHz", s.cpu.pFrequency); put("cpuW", s.cpu.power)
            put("cpuC", s.cpu.temperature); put("gpuPercent", s.gpu.usage); put("gpuGHz", s.gpu.frequency)
            put("gpuC", s.gpu.temperature); put("gpuW", s.gpu.power); put("aneW", s.gpu.anePower)
            put("memoryUsed", s.memory.used); put("memoryPressure", s.memory.pressure)
            put("memoryApp", s.memory.app); put("memoryReusable", s.memory.reusable)
            put("memoryWired", s.memory.wired); put("memoryCompressed", s.memory.compressed)
            metrics["diskTotalBytes"] = s.disk.totalBytes
            put("diskUsedBytes", s.disk.used); put("diskAvailableBytes", s.disk.available)
            if !s.diskVolumes.isEmpty {
                metrics["diskVolumes"] = s.diskVolumes.map {
                    ["name": $0.name, "path": $0.mountPath, "device": $0.deviceIdentifier as Any? ?? NSNull(),
                     "filesystem": $0.fileSystem, "sharedCapacity": $0.sharesCapacity,
                     "used": $0.used.shownValue as Any? ?? NSNull()]
                }
            }
            if !s.diskDrives.isEmpty {
                metrics["diskDrives"] = s.diskDrives.map {
                    ["id": $0.id, "name": $0.name, "volumes": $0.volumes.map(\.id),
                     "total": $0.totalBytes as Any? ?? NSNull(), "used": $0.used.shownValue as Any? ?? NSNull(),
                     "available": $0.available.shownValue as Any? ?? NSNull(),
                     "scope": $0.capacityScopeName as Any? ?? NSNull(),
                     "allocated": $0.allocated?.shownValue as Any? ?? NSNull(),
                     "reclaimable": $0.reclaimable?.shownValue as Any? ?? NSNull()]
                }
            }
            put("inputW", s.power.input); put("systemW", s.power.system); put("batteryW", s.power.battery)
            put("batteryState", s.power.batteryState); put("adapterConnected", s.power.adapterConnected)
            metrics["type"] = "sample"; metrics["epoch"] = Date().timeIntervalSince1970
            metrics["energyTimestamp"] = s.cpu.power.timestamp.map { $0 + Date.timeIntervalBetween1970AndReferenceDate }
            metrics["energyWindow"] = s.cpu.power.window
            metrics["elapsed"] = ProcessInfo.processInfo.systemUptime - began
            metrics["throttle"] = native.throttleStatus.isActive
            metrics["gpuThrottleAvailable"] = native.gpuThrottleStatus.isAvailable
            metrics["gpuThrottling"] = native.gpuThrottleStatus.isAvailable ? native.gpuThrottleStatus.isActive as Any : NSNull()
            metrics["corePercent"] = s.cpu.cores.map { $0.value as Any? ?? NSNull() }
            if mode == "processes" || mode == "memory" {
                metrics["inaccessibleProcesses"] = native.processMemory.inaccessibleProcessCount
                metrics["processes"] = native.processMemory.entries.map {
                    ["pid": $0.pid, "name": $0.name, "bytes": $0.memoryBytes] as [String: Any]
                }
            }
            emit(metrics)
        }
        emit(["type": "summary", "sampleCount": engine.core.sampleCount, "wakeCount": engine.wakeCount,
              "maxSampleMilliseconds": Dictionary(uniqueKeysWithValues: native.maximumSampleMilliseconds.map { ($0.key.rawValue, $0.value) }),
              "historyCounts": Dictionary(uniqueKeysWithValues: engine.history.recordedKeys.map { ($0.rawValue, engine.history.count($0)) })])
        engine.setUserPaused(true)
    }

    @MainActor
    private static func benchmarkHistory() {
        // Same samples and scheduling, alternating only the per-core history demand.
        let steps = 10_000
        for trial in 0..<8 {
            let active = trial % 2 == 0
            let core = MonitorCore(provider: FixtureProvider(scenario: .typical, anchor: 1000))
            core.setUserInterval(2, now: 1000)
            core.setDemand(.coreHistory, active: active, now: 1000)
            core.start(now: 1000)
            let start = ContinuousClock.now
            for step in 0..<steps { core.tick(now: 1000 + Double(step * 2)) }
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let coreBytes = core.history.recordedKeys.filter(\.isPerCore).reduce(0) { total, key in
                total + (core.history.series(key).map { $0.capacity * MemoryLayout<HistorySample>.stride } ?? 0)
            }
            let aggregateCounts = Dictionary(uniqueKeysWithValues: SeriesKey.aggregateKeys.map { ($0.rawValue, core.history.count($0)) })
            emit(["type": "historyBenchmark", "trial": trial, "coreHistory": active,
                  "seconds": seconds, "simulatedTicks": steps, "sampleCount": core.sampleCount,
                  "coreBufferBytes": coreBytes, "aggregateHistoryCounts": aggregateCounts])
        }
    }

    @MainActor
    private static func exercise(_ engine: MonitorEngine) async throws {
        var usage = SelfUsageSampler()
        try await Task.sleep(for: .seconds(3))
        for index in 0..<30 {
            engine.setUserPaused(true)
            let samples = engine.core.sampleCount
            try await Task.sleep(for: .milliseconds(150))
            precondition(engine.core.sampleCount == samples, "Pause sampled hardware")
            engine.suspend(.sleep)
            engine.resume(.sleep)
            precondition(engine.core.userPaused, "Wake cancelled user pause")
            engine.setUserPaused(false)
            try await Task.sleep(for: .seconds(2.1))
            if index % 5 == 0 {
                engine.forceStopped(.sensors)
                engine.retryStopped()
                try await Task.sleep(for: .seconds(1))
                precondition(engine.core.sources[.sensors]?.phase == .active, "SMC retry did not reopen")
            }
            let current = usage.sample(at: MonitorEngine.now, window: 1)
            emit(["type": "lifecycle", "cycle": index + 1, "samples": engine.core.sampleCount,
                  "footprintBytes": current.footprint.value ?? -1,
                  "energyWindow": engine.snapshot.cpu.power.window,
                  "historyPoints": engine.history.count(.cpuPower)])
        }
        engine.setTemperatureSource(.sensor("XXXX"))
        try await Task.sleep(for: .seconds(2.1))
        precondition(engine.snapshot.cpu.temperature.unavailableReason == .sensorMissing, "Missing sensor produced a reading")
        engine.setTemperatureSource(.cpuMax)
        try await Task.sleep(for: .seconds(2.1))
        precondition(engine.snapshot.cpu.temperature.status == .valid, "Temperature source did not recover")
        engine.setUserPaused(true)
        emit(["type": "lifecycleSummary", "cycles": 30, "pauseStopsSampling": true,
              "wakePreservesPause": true, "smcReconnects": 6, "missingSensorAndRecovery": true])
    }

    private static func emit(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) { print(string); fflush(stdout) }
    }
}
