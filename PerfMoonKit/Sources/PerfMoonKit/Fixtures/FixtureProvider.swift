// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Simulated data for the UI prototype. Contains no hardware access of any kind.
@MainActor
public final class FixtureProvider: MetricProvider {
    public let machine = MachineInfo(
        chipName: "Apple M5 Pro",
        shortChipName: "M5 Pro",
        gpuCoreCount: 20,
        physicalMemory: 64 * 1024 * 1024 * 1024
    )
    public let sensors: [SensorInfo] = FixtureSensors.all

    public private(set) var scenario: FixtureScenario = .typical
    public private(set) var behaviors: [SourceID: SimulatedBehavior] = [:]
    /// Sources with a live mock subscription.
    public private(set) var openSources: Set<SourceID> = []
    /// Mock subscription generation per source; increases on every rebuild.
    public private(set) var generations: [SourceID: Int] = [:]
    /// Open attempts since the last successful subscription.
    public private(set) var failedOpens: [SourceID: Int] = [:]
    public private(set) var missingSensors: Set<String> = []

    private var model: FixtureModel
    private var staleDelivered: Set<JobID> = []
    private var cachedWorld: (time: TimeInterval, world: FixtureWorld)?
    public private(set) var processMemory = ProcessMemorySnapshot()
    public var throttleStatus: ThrottleStatus {
        scenario == .thermalThrottle
            ? ThrottleStatus(isActive: true, explanation: "Simulated thermal-throttle evidence.")
            : .normal
    }
    public var gpuThrottleStatus: ThrottleStatus { throttleStatus }

    public init(scenario: FixtureScenario = .typical, anchor: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        self.model = FixtureModel(scenario: scenario, anchor: anchor)
        configure(scenario, anchor: anchor)
    }

    public func configure(_ scenario: FixtureScenario, anchor: TimeInterval) {
        self.scenario = scenario
        model = FixtureModel(scenario: scenario, anchor: anchor)
        behaviors = scenario.behaviors
        missingSensors = scenario.missingSensors
        openSources = []
        failedOpens = [:]
        staleDelivered = []
        cachedWorld = nil
        processMemory = ProcessMemorySnapshot()
    }

    public func behavior(for source: SourceID) -> SimulatedBehavior {
        behaviors[source] ?? .normal
    }

    public func setBehavior(_ behavior: SimulatedBehavior, for source: SourceID) {
        behaviors[source] = behavior == .normal ? nil : behavior
        failedOpens[source] = 0
        staleDelivered = staleDelivered.filter { $0.source != source }
    }

    public func setSensor(_ id: String, missing: Bool) {
        if missing { missingSensors.insert(id) } else { missingSensors.remove(id) }
    }

    // MARK: MetricProvider

    public func open(_ source: SourceID, at time: TimeInterval) -> OpenResult {
        let result: OpenResult
        switch behavior(for: source) {
        case .normal, .stale:
            result = .opened
        case .failing:
            result = .failed(.transient)
        case .recoversOnThirdAttempt:
            let attempts = (failedOpens[source] ?? 0) + 1
            if attempts >= 3 {
                behaviors[source] = nil
                result = .opened
            } else {
                failedOpens[source] = attempts
                result = .failed(.transient)
            }
        case .unsupported:
            result = .failed(.unsupported)
        case .unknownOSVersion:
            result = .failed(.unknownOSVersion)
        case .permissionDenied:
            result = .failed(.permissionDenied)
        }
        if result == .opened {
            openSources.insert(source)
            generations[source, default: 0] += 1
            failedOpens[source] = 0
            staleDelivered = staleDelivered.filter { $0.source != source }
        } else if case .failed(let failure) = result, failure == .transient, behavior(for: source) == .failing {
            failedOpens[source, default: 0] += 1
        }
        return result
    }

    public func close(_ source: SourceID) {
        openSources.remove(source)
        if source == .processMemory { processMemory = ProcessMemorySnapshot() }
    }

    public func rebaseline(_ source: SourceID, at time: TimeInterval) {
        // Fixture values are pure functions of time; nothing to capture.
    }

    public func sample(_ job: JobID, request: SampleRequest, at time: TimeInterval) -> SampleOutcome {
        guard let source = job.source, openSources.contains(source) else {
            return .failed(.transient)
        }
        switch behavior(for: source) {
        case .normal:
            break
        case .stale:
            if staleDelivered.contains(job) { return .noNewData }
            staleDelivered.insert(job)
        case .failing, .recoversOnThirdAttempt:
            return .failed(.transient)
        case .unsupported:
            return .failed(.unsupported)
        case .unknownOSVersion:
            return .failed(.unknownOSVersion)
        case .permissionDenied:
            return .failed(.permissionDenied)
        }
        if job == .processMemory {
            let labels = ["Example Model", "Example Browser", "Example VM", "Example Editor", "Example Helper", "Example App 6", "Example App 7", "Example App 8", "Example App 9", "Example App 10"]
            processMemory = ProcessMemorySnapshot(entries: labels.enumerated().map {
                let rank = $0.offset + 1
                var row = ProcessMemoryEntry(pid: Int32(2000 + $0.offset), name: $0.element, memoryBytes: Double(12_000_000_000 / rank))
                row.cpuPercent = 296 / Double(rank)
                row.readBytesPerSecond = Double((rank * 17) % 11) * 280_000
                row.writeBytesPerSecond = Double((rank * 9) % 11) * 105_000
                return row
            }, status: .valid, timestamp: time)
            processMemory.byCPU = processMemory.entries.sorted { $0.cpuPercent > $1.cpuPercent }
            processMemory.byRead = processMemory.entries.sorted { $0.readBytesPerSecond > $1.readBytesPerSecond }
            processMemory.byWrite = processMemory.entries.sorted { $0.writeBytesPerSecond > $1.writeBytesPerSecond }
            processMemory.rateWindow = 5
        }
        if job == .diskActivity {
            let world = world(at: time)
            return .diskActivity([("disk0", UInt64(1), 1.0), ("disk5", UInt64(2), 0.3)].map { device, id, factor in
                DiskActivity(id: id, device: device,
                             bytes: TransferRates(incoming: world.total * 420_000 * factor, outgoing: world.gpuUsage * 210_000 * factor,
                                                  at: time, window: request.interval, source: .diskActivity),
                             operations: TransferRates(incoming: world.total * 5 * factor, outgoing: world.gpuUsage * 3 * factor,
                                                       at: time, window: request.interval, source: .diskActivity, unit: .perSecond))
            })
        }
        if job == .network {
            let links = [NetworkInterfaceInfo(id: "en0", index: 1, name: "Wi-Fi", isHardware: true),
                         NetworkInterfaceInfo(id: "utun2", index: 2, name: "Tunnel", isHardware: false)]
            let selected = links.first { $0.id == (request.networkInterface ?? "en0") }
            let world = world(at: time)
            let rates = selected.map { link in
                TransferRates(incoming: world.total * 120_000 / Double(link.index), outgoing: world.gpuUsage * 35_000 / Double(link.index),
                              at: time, window: request.interval, source: .network)
            } ?? TransferRates(status: .unavailable(.interfaceDisconnected), source: .network)
            return .network(NetworkActivity(interfaces: links, selected: selected, rates: rates,
                                            receivedBytes: selected == nil ? nil : 12_678_435_210, sentBytes: selected == nil ? nil : 3_801_372_984))
        }
        if job == .disk {
            let boot = DiskSnapshot(id: "fixture-startup", name: "Macintosh HD", mountPath: "/", deviceIdentifier: "disk3s1s1",
                                    isInternal: true, totalBytes: 1_000_000_000_000, availableBytes: 620_000_000_000, at: time,
                                    fileSystem: "APFS", sharesCapacity: true, individualUsed: 380_000_000_000)
            let external = DiskSnapshot(id: "fixture-external", name: "Archive SSD", mountPath: "/Volumes/Archive SSD", deviceIdentifier: "disk5s1",
                                        isInternal: false, totalBytes: 2_000_000_000_000, availableBytes: 850_000_000_000, at: time, fileSystem: "exFAT")
            return .diskDrives([
                DiskDriveSnapshot(id: "disk0", name: "Internal SSD", isInternal: true, volumes: [boot],
                                  totalBytes: boot.totalBytes, availableBytes: boot.available.shownValue, at: time),
                DiskDriveSnapshot(id: "disk5", name: "External SSD", isInternal: false, volumes: [external],
                                  totalBytes: external.totalBytes, availableBytes: external.available.shownValue, at: time),
            ])
        }
        return .values(values(for: job, request: request, world: world(at: time)))
    }

    // MARK: Values

    func world(at time: TimeInterval) -> FixtureWorld {
        if let cachedWorld, cachedWorld.time == time { return cachedWorld.world }
        let world = model.world(at: time)
        cachedWorld = (time, world)
        return world
    }

    private func values(for job: JobID, request: SampleRequest, world: FixtureWorld) -> [MetricKey: Double] {
        var values: [MetricKey: Double] = [:]
        switch job {
        case .cpuActivity:
            values[.cpuTotal] = world.total
            values[.cpuS] = world.sMean
            values[.cpuP] = world.pMean
            for (index, load) in world.cores.enumerated() { values[.core(index)] = load }
        case .corePower:
            let load = max(1, world.cores.reduce(0, +))
            for (index, usage) in world.cores.enumerated() { values[.corePower(index)] = world.cpuPower * usage / load }
        case .cpuFrequency:
            values[.cpuFrequencyS] = world.sFrequency
            values[.cpuFrequencyP] = world.pFrequency
        case .energy:
            values[.cpuPower] = world.cpuPower
            values[.gpuPower] = world.gpuPower
            values[.anePower] = world.anePower
        case .gpuActivity:
            values[.gpuUsage] = world.gpuUsage
            values[.gpuFrequency] = world.gpuFrequency
        case .powerSensors:
            values[.powerInput] = world.powerInput
            values[.powerSystem] = world.powerSystem
            values[.powerBattery] = world.powerBattery
        case .battery:
            values[.batteryState] = Double(world.batteryState.rawValue)
            values[.adapterConnected] = world.adapterConnected ? 1 : 0
        case .memory:
            values = world.memory
        case .memoryPressure:
            values[.memoryPressure] = Double(world.pressure.rawValue)
        case .temperatures, .sensorCatalog:
            for id in request.sensorIDs where !missingSensors.contains(id) {
                if let value = world.temperatures[id] { values[.sensor(id)] = value }
            }
        case .selfUsage, .thermal, .processMemory, .disk, .diskActivity, .network:
            break
        }
        for key in request.warmingKeys { values[key] = nil }
        return values
    }

    // MARK: History prefill

    /// Writes coherent history so charts can be reviewed immediately.
    public func prefill(_ history: HistoryStore, now: TimeInterval, temperatureSource: TemperatureSource) {
        var times: [(time: TimeInterval, interval: TimeInterval)] = []
        switch scenario.historyPlan {
        case .full:
            for t in stride(from: now - 898, through: now - 2, by: 2) { times.append((t, 2)) }
        case .recent(let seconds, let gapFrom, let gapTo):
            for t in stride(from: now - seconds, through: now - 1, by: 1) where !(t > now - gapFrom && t < now - gapTo) {
                times.append((t, 1))
            }
        case .sleepGap(let from, _):
            for t in stride(from: now - 898, through: now - from, by: 2) { times.append((t, 2)) }
        case .mixedIntervals:
            for t in stride(from: now - 898, through: now - 600, by: 1) { times.append((t, 1)) }
            for t in stride(from: now - 595, through: now - 300, by: 5) { times.append((t, 5)) }
            for t in stride(from: now - 298, through: now - 2, by: 2) { times.append((t, 2)) }
        }

        let absent: Set<SourceID> = Set(behaviors.compactMap { source, behavior in
            switch behavior {
            case .unsupported, .unknownOSVersion, .permissionDenied: source
            default: nil
            }
        })
        let endsEarly: Set<SourceID> = Set(scenario.startsStopped)
        let failedSensorEnd: TimeInterval? = {
            if case .sensor(let id) = temperatureSource, missingSensors.contains(id) { return now - 40 }
            return nil
        }()

        for (time, interval) in times {
            let world = model.world(at: time)
            func add(_ key: SeriesKey, _ value: Double?) {
                guard let value else { return }
                let source = key.source
                if absent.contains(source) { return }
                if endsEarly.contains(source), time > now - 75 { return }
                history.append(key, time: time, value: value, expectedInterval: interval)
            }
            add(.cpuTotal, world.total)
            add(.cpuS, world.sMean)
            add(.cpuP, world.pMean)
            let totalLoad = max(1, world.cores.reduce(0, +))
            for core in CoreID.all {
                add(.corePower(core), world.cpuPower * world.cores[core.flatIndex] / totalLoad)
                add(.coreUsage(core), world.cores[core.flatIndex])
                if let sensor = sensors.first(where: { $0.mappedCore == core }),
                   !missingSensors.contains(sensor.id) {
                    add(.coreTemperature(core), world.temperatures[sensor.id])
                }
            }
            add(.cpuFrequencyS, world.sFrequency)
            add(.cpuFrequencyP, world.pFrequency)
            add(.cpuPower, world.cpuPower)
            add(.gpuUsage, world.gpuUsage)
            add(.gpuFrequency, world.gpuFrequency)
            add(.gpuPower, world.gpuPower)
            add(.anePower, world.anePower)
            for (key, value) in world.memory {
                if let series = key.series { add(series, value) }
            }
            if let used = world.memory[.memoryUsed] {
                add(.memoryDetail(.available), max(0, machine.physicalMemory - used))
            }
            add(.memoryPressure, Double(world.pressure.rawValue))
            add(.powerInput, world.powerInput)
            add(.powerSystem, world.powerSystem)
            add(.powerBattery, world.powerBattery)
            add(.batteryState, Double(world.batteryState.rawValue))
            add(.gpuTemperature, world.gpuTemperature)
            if let failedSensorEnd, time > failedSensorEnd { continue }
            add(.cpuTemperature, world.cpuTemperature(for: temperatureSource))
        }
    }
}
