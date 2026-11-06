import Foundation

public struct SourceRuntime: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Not subscribed yet.
        case idle
        case active
        /// One recovery job per source. `attemptsMade` counts failed automatic attempts.
        case recovering(attemptsMade: Int, nextAttempt: TimeInterval)
        /// Automatic attempts exhausted; waits for Retry or a system recovery event.
        case stopped
        /// Not retried automatically.
        case unavailable(UnavailableReason)
    }

    public var phase: Phase = .idle
    public var lastUpdated: TimeInterval?
    public var baselineAt: TimeInterval?
    /// Number of successful subscriptions; increases each time a source is rebuilt.
    public var subscriptions = 0

    public var isRunnable: Bool {
        switch phase {
        case .idle, .active: true
        default: false
        }
    }

    public var reason: UnavailableReason? {
        switch phase {
        case .recovering: .retrying
        case .stopped: .stopped
        case .unavailable(let reason): reason
        case .idle, .active: nil
        }
    }
}

/// Deterministic scheduling and state machine. Time is always passed in, so tests can drive it.
@MainActor
public final class MonitorCore {
    public let provider: any MetricProvider
    public let history: HistoryStore

    public private(set) var userInterval: TimeInterval = 1
    public private(set) var temperatureSource: TemperatureSource = .cpuMax
    public private(set) var demands: Set<Demand> = []
    public private(set) var userPaused = false
    public private(set) var suspendReasons: Set<SuspendReason> = []
    public private(set) var started = false

    public private(set) var intervals: [JobID: TimeInterval] = [:]
    public private(set) var nextDue: [JobID: TimeInterval] = [:]
    public private(set) var sources: [SourceID: SourceRuntime] = [:]
    public private(set) var readings: [MetricKey: MetricReading] = [:]
    public private(set) var catalog: [String: MetricReading] = [:]
    public private(set) var selfUsage = SelfUsage.pending
    public private(set) var lastTick: TimeInterval = 0
    public private(set) var historyRevision = 0
    /// Number of times any job sampled a provider. Used to verify that Pause stops collection.
    public private(set) var sampleCount = 0

    /// Debug only: shortens recovery delays so the full backoff can be reviewed quickly.
    public var recoveryTimeScale: Double = 1

    private var epoch: TimeInterval = 0
    private var selfSampler = SelfUsageSampler()
    private var sensorIndex: [String: SensorInfo] = [:]
    private var cpuSensorIDs: [String] = []
    private var gpuSensorIDs: [String] = []
    private var mappedSensorIDs: [CoreID: String] = [:]
    private var lastTemperatureRequest: [String] = []
    private var processSnapshotIsFresh = false

    public static let dueTolerance: TimeInterval = 0.005
    public static let staleCycles: Double = 3

    public init(provider: any MetricProvider, history: HistoryStore = HistoryStore()) {
        self.provider = provider
        self.history = history
        resetState()
    }

    // MARK: - State

    public var systemSuspended: Bool { !suspendReasons.isEmpty }
    public var isCollecting: Bool { started && !userPaused && !systemSuspended }
    public var run: RunState { RunState(userPaused: userPaused, systemSuspended: systemSuspended) }

    public var machine: MachineInfo { provider.machine }
    public var sensors: [SensorInfo] { provider.sensors }

    public func sensorInfo(_ id: String) -> SensorInfo? { sensorIndex[id] }

    public func mappedSensor(for core: CoreID) -> String? { mappedSensorIDs[core] }

    /// Clears all collected state. Used when a fixture scenario is applied.
    public func resetState() {
        for source in SourceID.allCases { provider.close(source) }
        sensorIndex = Dictionary(uniqueKeysWithValues: provider.sensors.map { ($0.id, $0) })
        cpuSensorIDs = provider.sensors.filter { $0.category == .cpu }.map(\.id)
        gpuSensorIDs = provider.sensors.filter { $0.category == .gpu }.map(\.id)
        mappedSensorIDs = [:]
        for sensor in provider.sensors {
            if let core = sensor.mappedCore { mappedSensorIDs[core] = sensor.id }
        }
        readings = [:]
        catalog = [:]
        selfUsage = .pending
        selfSampler.reset()
        sources = Dictionary(uniqueKeysWithValues: SourceID.allCases.map { ($0, SourceRuntime()) })
        nextDue = [:]
        for job in JobID.allCases {
            for key in job.keys {
                readings[key] = .pending(key.unit, source: job.source, quality: key.quality)
            }
        }
        readings[.cpuTemperature] = .pending(.celsius, source: .sensors, quality: .derived)
        readings[.gpuTemperature] = .pending(.celsius, source: .sensors, quality: .derived)
        lastTemperatureRequest = []
        processSnapshotIsFresh = false
        historyRevision += 1
    }

    /// Makes every scheduled job due at `time`. Used after a reset.
    public func rescheduleAll(at time: TimeInterval) {
        for job in intervals.keys {
            nextDue[job] = time
        }
    }

    public func refresh(_ job: JobID, now: TimeInterval) {
        guard intervals[job] != nil else { return }
        nextDue[job] = now
    }

    public func start(now: TimeInterval) {
        guard !started else { return }
        started = true
        epoch = now.rounded(.down)
        replan(now: now)
    }

    public func setUserInterval(_ interval: TimeInterval, now: TimeInterval) {
        guard interval != userInterval else { return }
        userInterval = interval
        replan(now: now)
    }

    public func setDemand(_ demand: Demand, active: Bool, now: TimeInterval) {
        let changed = active ? demands.insert(demand).inserted : demands.remove(demand) != nil
        guard changed else { return }
        if demand == .performancePage, active { selfSampler.reset() }
        if demand == .coreHistory, !active {
            for key in SeriesKey.allCases where key.isPerCore { history.markBreak(key) }
            historyRevision += 1
        }
        if demand == .memoryProcesses || demand == .windowMemoryProcesses {
            // After the final consumer closes, reopening waits for a new scan.
            if !demands.contains(.memoryProcesses) && !demands.contains(.windowMemoryProcesses) {
                processSnapshotIsFresh = false
                provider.close(.processMemory)
                sources[.processMemory]?.phase = .idle
                sources[.processMemory]?.lastUpdated = nil
                sources[.processMemory]?.baselineAt = nil
            }
        }
        replan(now: now)
    }

    public func discardCoreHistory() {
        for key in SeriesKey.allCases where key.isPerCore { history.remove(key) }
        historyRevision += 1
    }

    /// A source change starts a new temperature series; the old one is discarded, never relabeled.
    public func setTemperatureSource(_ source: TemperatureSource, now: TimeInterval) {
        guard source != temperatureSource else { return }
        temperatureSource = source
        history.clear(.cpuTemperature)
        readings[.cpuTemperature] = .pending(.celsius, source: .sensors, quality: .derived)
        updateDerivedTemperatures(now: now, appendHistory: false)
        if intervals[.temperatures] != nil { nextDue[.temperatures] = now }
        historyRevision += 1
    }

    public func setUserPaused(_ paused: Bool, now: TimeInterval) {
        guard paused != userPaused else { return }
        let wasCollecting = isCollecting
        userPaused = paused
        transition(wasCollecting: wasCollecting, now: now)
    }

    public func suspend(_ reason: SuspendReason, now: TimeInterval) {
        guard !suspendReasons.contains(reason) else { return }
        let wasCollecting = isCollecting
        suspendReasons.insert(reason)
        transition(wasCollecting: wasCollecting, now: now)
    }

    /// Waking never cancels a user pause.
    public func resume(_ reason: SuspendReason, now: TimeInterval) {
        guard suspendReasons.contains(reason) else { return }
        let wasCollecting = isCollecting
        suspendReasons.remove(reason)
        transition(wasCollecting: wasCollecting, now: now)
    }

    private func transition(wasCollecting: Bool, now: TimeInterval) {
        if wasCollecting, !isCollecting {
            history.markBreakAll()
            historyRevision += 1
        } else if !wasCollecting, isCollecting {
            resumeCollection(now: now)
        }
    }

    private func resumeCollection(now: TimeInterval) {
        history.markBreakAll()
        for source in SourceID.allCases {
            guard var runtime = sources[source] else { continue }
            if case .active = runtime.phase, source.isDifferenced {
                provider.rebaseline(source, at: now)
                runtime.baselineAt = now
                sources[source] = runtime
                markWarming(source, differencedOnly: true)
            }
        }
        recoveryEvent(now: now)
        for job in intervals.keys {
            nextDue[job] = now
        }
        historyRevision += 1
    }

    /// Wake, Resume, and power source changes retry stopped sources once.
    public func recoveryEvent(now: TimeInterval) {
        guard isCollecting else { return }
        for source in SourceID.allCases where sources[source]?.phase == .stopped {
            retry(source, now: now)
        }
    }

    /// Manual Retry: one immediate attempt; if it fails transiently, a new recovery job begins.
    public func retry(_ source: SourceID, now: TimeInterval) {
        guard let runtime = sources[source] else { return }
        switch runtime.phase {
        case .stopped:
            break
        case .unavailable(let reason) where reason.isRetryable:
            break
        default:
            return
        }
        attemptOpen(source, now: now, attemptsMade: nil)
    }

    // MARK: - Scheduling

    private func replan(now: TimeInterval) {
        let planned = SchedulePlanner.intervals(userInterval: userInterval, demands: demands)
        for (job, interval) in planned {
            if let previous = intervals[job], nextDue[job] != nil {
                if interval < previous {
                    nextDue[job] = alignedNext(after: now, interval: interval)
                }
            } else {
                nextDue[job] = now
            }
        }
        for job in intervals.keys where planned[job] == nil {
            nextDue[job] = nil
        }
        intervals = planned

        if temperatureRequest() != lastTemperatureRequest {
            nextDue[.temperatures] = now
        }
    }

    private func alignedNext(after time: TimeInterval, interval: TimeInterval) -> TimeInterval {
        let steps = ((time - epoch) / interval + 1e-6).rounded(.down) + 1
        return epoch + steps * interval
    }

    /// The next time the run loop must wake, or nil when nothing needs work.
    public func nextWakeTime() -> TimeInterval? {
        guard isCollecting else { return nil }
        var earliest: TimeInterval?
        for (job, due) in nextDue {
            if let source = job.source, sources[source]?.isRunnable == false { continue }
            earliest = min(earliest ?? due, due)
        }
        for runtime in sources.values {
            if case .recovering(_, let next) = runtime.phase {
                earliest = min(earliest ?? next, next)
            }
        }
        return earliest
    }

    public func tick(now: TimeInterval) {
        guard isCollecting else { return }
        lastTick = now

        for source in SourceID.allCases {
            if case .recovering(let made, let next) = sources[source]?.phase, next <= now + Self.dueTolerance {
                attemptOpen(source, now: now, attemptsMade: made)
            }
        }

        var ranAny = false
        for job in JobID.allCases {
            guard let due = nextDue[job], due <= now + Self.dueTolerance, let interval = intervals[job] else { continue }
            run(job, interval: interval, now: now)
            nextDue[job] = alignedNext(after: max(now, due), interval: interval)
            ranAny = true
        }
        if ranAny { historyRevision += 1 }
    }

    // MARK: - Jobs

    private func run(_ job: JobID, interval: TimeInterval, now: TimeInterval) {
        if job == .selfUsage {
            selfUsage = selfSampler.sample(at: now, window: interval)
            return
        }
        guard let source = job.source, let runtime = sources[source] else { return }
        switch runtime.phase {
        case .idle:
            attemptOpen(source, now: now, attemptsMade: nil)
            guard sources[source]?.phase == .active else { return }
        case .active:
            break
        case .recovering, .stopped, .unavailable:
            return
        }

        let baselineAge = now - (sources[source]?.baselineAt ?? -.infinity)
        let warming: Set<MetricKey> = source.isDifferenced && baselineAge < 0.25 * interval
            ? Set(job.keys.filter(\.isDifferenced))
            : []

        var request = SampleRequest(warmingKeys: warming)
        switch job {
        case .temperatures:
            request.sensorIDs = temperatureRequest()
            lastTemperatureRequest = request.sensorIDs
        case .sensorCatalog:
            request.sensorIDs = provider.sensors.map(\.id)
        default:
            break
        }

        sampleCount += 1
        let outcome = provider.sample(job, request: request, at: now)
        switch outcome {
        case .failed(let failure):
            handleFailure(source, failure: failure, now: now)
        case .noNewData:
            markStaleIfNeeded(job, interval: interval, now: now)
        case .values(let values):
            sources[source]?.lastUpdated = now
            if job == .processMemory { processSnapshotIsFresh = true }
            apply(values, job: job, request: request, interval: interval, now: now)
        case .measured(let values, let window):
            sources[source]?.lastUpdated = now
            if job == .processMemory { processSnapshotIsFresh = true }
            apply(values, job: job, request: request, interval: interval, now: now, sampleWindow: window)
        }
    }

    private func apply(_ values: [MetricKey: Double], job: JobID, request: SampleRequest, interval: TimeInterval, now: TimeInterval, sampleWindow: TimeInterval? = nil) {
        switch job {
        case .temperatures:
            let requested = Set(request.sensorIDs)
            for key in readings.keys {
                if case .sensor(let id) = key, !requested.contains(id) { readings[key] = nil }
            }
            for id in request.sensorIDs {
                let key = MetricKey.sensor(id)
                if let value = values[key] {
                    readings[key] = MetricReading(value: value, unit: .celsius, status: .valid, timestamp: now, window: 0, source: .sensors, quality: .observed)
                } else {
                    readings[key] = MetricReading(value: nil, unit: .celsius, status: .unavailable(.sensorMissing), source: .sensors, quality: .observed)
                }
            }
            updateDerivedTemperatures(now: now, appendHistory: true)
            return
        case .sensorCatalog:
            for id in request.sensorIDs {
                if let value = values[.sensor(id)] {
                    catalog[id] = MetricReading(value: value, unit: .celsius, status: .valid, timestamp: now, window: 0, source: .sensors, quality: .observed)
                } else {
                    catalog[id] = MetricReading(value: nil, unit: .celsius, status: .unavailable(.sensorMissing), source: .sensors, quality: .observed)
                }
            }
            return
        default:
            break
        }

        for key in job.keys {
            if request.warmingKeys.contains(key) {
                readings[key] = .pending(key.unit, source: job.source, quality: key.quality)
                continue
            }
            guard let value = values[key] else {
                if key == .memoryReusable {
                    readings[key] = MetricReading(value: nil, unit: .bytes, status: .unavailable(.unsupported), source: .memory)
                    continue
                }
                // The provider had nothing new for this key.
                if var reading = readings[key], let timestamp = reading.timestamp,
                   now - timestamp > Self.staleCycles * interval, reading.status == .valid {
                    reading.status = .stale
                    readings[key] = reading
                }
                continue
            }
            guard value.isFinite else { continue }
            readings[key] = MetricReading(value: value, unit: key.unit, status: .valid, timestamp: now, window: key.isDifferenced ? (sampleWindow ?? interval) : 0, source: job.source, quality: key.quality)
            if let series = key.series {
                if case .core = key, !demands.contains(.coreHistory) { continue }
                history.append(series, time: now, value: value, expectedInterval: interval)
            }
        }
    }

    private func markStaleIfNeeded(_ job: JobID, interval: TimeInterval, now: TimeInterval) {
        for key in job.keys {
            guard var reading = readings[key], reading.status == .valid, let timestamp = reading.timestamp else { continue }
            if now - timestamp > Self.staleCycles * interval {
                reading.status = .stale
                readings[key] = reading
            }
        }
    }

    // MARK: - Temperatures

    func temperatureRequest() -> [String] {
        var ids = Set<String>()
        switch temperatureSource {
        case .cpuMax, .cpuAverage:
            ids.formUnion(cpuSensorIDs)
        case .sensor(let id):
            ids.insert(id)
        }
        ids.formUnion(gpuSensorIDs)
        if demands.contains(.window(.cpu)) {
            ids.formUnion(mappedSensorIDs.values)
        }
        return ids.sorted()
    }

    private func updateDerivedTemperatures(now: TimeInterval, appendHistory: Bool) {
        let interval = intervals[.temperatures] ?? SchedulePlanner.temperatureFloor
        let sourceReason = sources[.sensors]?.reason

        func aggregate(_ ids: [String], _ combine: ([Double]) -> Double) -> MetricReading {
            let present = ids.compactMap { readings[.sensor($0)] }
            let values = present.filter { $0.status == .valid || $0.status == .stale }.compactMap(\.value)
            guard !values.isEmpty else {
                if let sourceReason {
                    return MetricReading(value: nil, unit: .celsius, status: .unavailable(sourceReason), source: .sensors, quality: .derived)
                }
                let anyMissing = present.contains { $0.unavailableReason == .sensorMissing }
                return MetricReading(value: nil, unit: .celsius, status: anyMissing ? .unavailable(.sensorMissing) : .warming, source: .sensors, quality: .derived)
            }
            let timestamp = present.compactMap(\.timestamp).max()
            let allStale = present.allSatisfy { $0.status != .valid }
            return MetricReading(value: combine(values), unit: .celsius, status: allStale ? .stale : .valid, timestamp: timestamp, window: 0, source: .sensors, quality: .derived)
        }

        let cpu: MetricReading
        switch temperatureSource {
        case .cpuMax:
            cpu = aggregate(cpuSensorIDs) { $0.max() ?? 0 }
        case .cpuAverage:
            cpu = aggregate(cpuSensorIDs) { $0.reduce(0, +) / Double($0.count) }
        case .sensor(let id):
            if let reading = readings[.sensor(id)] {
                cpu = reading
            } else if let sourceReason {
                cpu = MetricReading(value: nil, unit: .celsius, status: .unavailable(sourceReason), source: .sensors)
            } else {
                cpu = .pending(.celsius, source: .sensors)
            }
        }
        readings[.cpuTemperature] = cpu
        let gpu = aggregate(gpuSensorIDs) { $0.max() ?? 0 }
        readings[.gpuTemperature] = gpu

        for core in CoreID.all {
            if let id = mappedSensorIDs[core], let reading = readings[.sensor(id)] {
                readings[.coreTemperature(core.flatIndex)] = reading
            } else {
                readings[.coreTemperature(core.flatIndex)] = nil
            }
        }

        guard appendHistory else { return }
        // A selected custom sensor may leave other cores unrequested in the
        // background. Record only fresh mapped reads; never extend a cached
        // value into a period when that core was not actually sampled.
        for core in CoreID.all where demands.contains(.coreHistory) {
            let key = SeriesKey.coreTemperature(core)
            if let reading = readings[.coreTemperature(core.flatIndex)],
               reading.status == .valid, reading.timestamp == now,
               let value = reading.value, value.isFinite {
                history.append(key, time: now, value: value, expectedInterval: interval)
            } else {
                history.markBreak(key)
            }
        }
        for (key, reading) in [(SeriesKey.cpuTemperature, cpu), (.gpuTemperature, gpu)] {
            if reading.status == .valid, reading.timestamp == now, let value = reading.value {
                history.append(key, time: now, value: value, expectedInterval: interval)
            } else if reading.status != .valid {
                history.markBreak(key)
            }
        }
    }

    // MARK: - Failures and recovery

    private func attemptOpen(_ source: SourceID, now: TimeInterval, attemptsMade: Int?) {
        switch provider.open(source, at: now) {
        case .opened:
            var runtime = sources[source] ?? SourceRuntime()
            runtime.phase = .active
            runtime.baselineAt = now
            runtime.subscriptions += 1
            sources[source] = runtime
            markWarming(source, differencedOnly: false)
            history.markBreak(source: source)
            for job in source.jobs where intervals[job] != nil {
                nextDue[job] = now
            }
        case .failed(let failure):
            provider.close(source)
            if failure == .transient {
                let made = (attemptsMade ?? -1) + 1
                if attemptsMade != nil, made >= RecoveryPolicy.maxAttempts {
                    setPhase(source, .stopped)
                } else {
                    let delay = RecoveryPolicy.delays[min(made, RecoveryPolicy.maxAttempts - 1)] * recoveryTimeScale
                    setPhase(source, .recovering(attemptsMade: made, nextAttempt: now + delay))
                }
            } else {
                setPhase(source, .unavailable(failure.reason))
            }
        }
    }

    private func handleFailure(_ source: SourceID, failure: SourceFailure, now: TimeInterval) {
        // Release the broken subscription before any rebuild.
        provider.close(source)
        if failure == .transient {
            setPhase(source, .recovering(attemptsMade: 0, nextAttempt: now + RecoveryPolicy.delays[0] * recoveryTimeScale))
        } else {
            setPhase(source, .unavailable(failure.reason))
        }
    }

    private func setPhase(_ source: SourceID, _ phase: SourceRuntime.Phase) {
        sources[source, default: SourceRuntime()].phase = phase
        let reason: UnavailableReason?
        switch phase {
        case .recovering: reason = .retrying
        case .stopped: reason = .stopped
        case .unavailable(let value): reason = value
        case .idle, .active: reason = nil
        }
        if let reason {
            markUnavailable(source, reason: reason)
        }
        history.markBreak(source: source)
        historyRevision += 1
    }

    private func markUnavailable(_ source: SourceID, reason: UnavailableReason) {
        for job in source.jobs {
            for key in job.keys {
                readings[key, default: .pending(key.unit, source: source, quality: key.quality)].status = .unavailable(reason)
            }
        }
        if source == .sensors {
            for key in readings.keys {
                switch key {
                case .sensor, .cpuTemperature, .gpuTemperature, .coreTemperature:
                    readings[key]?.status = .unavailable(reason)
                default:
                    break
                }
            }
            for id in catalog.keys {
                catalog[id]?.status = .unavailable(reason)
            }
        }
    }

    private func markWarming(_ source: SourceID, differencedOnly: Bool) {
        for job in source.jobs {
            for key in job.keys where !differencedOnly || key.isDifferenced {
                readings[key] = .pending(key.unit, source: source, quality: key.quality)
            }
        }
        if source == .sensors, !differencedOnly {
            for key in readings.keys {
                switch key {
                case .sensor, .cpuTemperature, .gpuTemperature, .coreTemperature:
                    readings[key]?.status = .warming
                    readings[key]?.value = nil
                default:
                    break
                }
            }
        }
    }

    // MARK: - Debug hooks

    /// Puts a source straight into the stopped state, as if its recovery job had run out.
    public func forceStopped(_ source: SourceID) {
        provider.close(source)
        setPhase(source, .stopped)
    }

    /// Triggers the failure path on the source's next sample by asking the provider to fail now.
    public func injectFailure(_ source: SourceID, failure: SourceFailure, now: TimeInterval) {
        handleFailure(source, failure: failure, now: now)
    }

    // MARK: - Snapshot

    public func reading(_ key: MetricKey) -> MetricReading {
        readings[key] ?? .pending(key.unit, quality: key.quality)
    }

    public func snapshot(now: TimeInterval) -> MonitorSnapshot {
        let cpu = CPUSnapshot(
            total: reading(.cpuTotal),
            sCore: reading(.cpuS),
            pCore: reading(.cpuP),
            sFrequency: reading(.cpuFrequencyS),
            pFrequency: reading(.cpuFrequencyP),
            power: reading(.cpuPower),
            temperature: reading(.cpuTemperature),
            temperatureSource: temperatureSource,
            cores: CoreID.all.map { reading(.core($0.flatIndex)) },
            coreTemperatures: CoreID.all.map { readings[.coreTemperature($0.flatIndex)] },
            throttle: provider.throttleStatus
        )
        let gpu = GPUSnapshot(
            usage: reading(.gpuUsage),
            frequency: reading(.gpuFrequency),
            temperature: reading(.gpuTemperature),
            power: reading(.gpuPower),
            anePower: reading(.anePower),
            throttle: provider.gpuThrottleStatus
        )
        let memory = MemorySnapshot(
            physical: provider.machine.physicalMemory,
            used: reading(.memoryUsed),
            app: reading(.memoryApp),
            wired: reading(.memoryWired),
            compressed: reading(.memoryCompressed),
            cached: reading(.memoryCached),
            purgeable: reading(.memoryPurgeable),
            reusable: reading(.memoryReusable),
            free: reading(.memoryFree),
            swapUsed: reading(.swapUsed),
            pageIns: reading(.pageIns),
            pageOuts: reading(.pageOuts),
            swapIns: reading(.swapIns),
            swapOuts: reading(.swapOuts),
            pressure: reading(.memoryPressure),
            processes: processSnapshotIsFresh ? provider.processMemory : ProcessMemorySnapshot()
        )
        let power = PowerSnapshot(
            input: reading(.powerInput),
            system: reading(.powerSystem),
            battery: reading(.powerBattery),
            batteryState: reading(.batteryState),
            adapterConnected: reading(.adapterConnected)
        )
        return MonitorSnapshot(
            time: isCollecting ? max(lastTick, now) : lastTick,
            run: run,
            cpu: cpu,
            gpu: gpu,
            memory: memory,
            power: power,
            prompt: prompt(),
            historyRevision: historyRevision
        )
    }

    public func prompt() -> PanelPrompt? {
        let stopped = SourceID.allCases.filter { sources[$0]?.phase == .stopped }
        if !stopped.isEmpty { return .retry(stopped) }
        if case .sensor(let id) = temperatureSource,
           readings[.cpuTemperature]?.unavailableReason == .sensorMissing,
           sources[.sensors]?.phase == .active {
            return .useCPUMax(sensorID: id)
        }
        return nil
    }

    public func sourceStatuses() -> [SourceStatus] {
        SourceID.allCases.map { source in
            let runtime = sources[source] ?? SourceRuntime()
            let interval = source.jobs.compactMap { intervals[$0] }.min()
            return SourceStatus(id: source, phase: runtime.phase, lastUpdated: runtime.lastUpdated, interval: interval)
        }
    }

    public func catalogReadings() -> [SensorReading] {
        provider.sensors.map { info in
            SensorReading(info: info, reading: catalog[info.id] ?? .pending(.celsius, source: .sensors))
        }
    }
}
