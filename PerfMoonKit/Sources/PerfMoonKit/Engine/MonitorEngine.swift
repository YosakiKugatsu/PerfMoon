// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Owns the one run loop. Every change goes through here so the loop is rescheduled
/// and observers see a fresh snapshot. The loop stops entirely when nothing is due.
@MainActor
public final class MonitorEngine {
    public let core: MonitorCore
    /// Retained for the Debug Design Gallery; live collection is the default.
    public let fixtures: FixtureProvider
    private let providerRouter: ProviderRouter
    public var isLive: Bool { providerRouter.isLive }
    public private(set) var snapshot: MonitorSnapshot
    public private(set) var scenario: FixtureScenario = .typical
    /// Number of times the run loop has woken. Debug only.
    public private(set) var wakeCount = 0

    private var loop: Task<Void, Never>?
    private var observers: [Int: @MainActor (MonitorEngine) -> Void] = [:]
    private var nextObserverID = 0

    public static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    public init(fixtures: FixtureProvider, liveProvider: (any MetricProvider)? = nil) {
        self.fixtures = fixtures
        let router = ProviderRouter(fixtures: fixtures, live: liveProvider)
        self.providerRouter = router
        let core = MonitorCore(provider: router)
        self.core = core
        self.snapshot = core.snapshot(now: MonitorEngine.now)
        core.onBackgroundSample = { [weak self] in self?.changed() }
    }

    public var history: HistoryStore { core.history }

    // MARK: Lifecycle

    public func start(scenario: FixtureScenario, interval: UpdateInterval, temperatureSource: TemperatureSource) {
        let now = Self.now
        core.setUserInterval(interval.rawValue, now: now)
        core.setTemperatureSource(temperatureSource, now: now)
        core.start(now: now)
        if isLive { changed() } else { apply(scenario: scenario) }
    }

    /// Replaces all collected state with a scenario. Debug and initial preview data.
    public func apply(scenario: FixtureScenario) {
        let now = Self.now
        providerRouter.useFixtures()
        self.scenario = scenario
        if core.userPaused { core.setUserPaused(false, now: now) }
        fixtures.configure(scenario, anchor: now)
        core.history.removeAll()
        core.resetState()
        fixtures.prefill(core.history, now: now, temperatureSource: core.temperatureSource)
        if !core.recordsCoreHistory { core.discardCoreHistory() }
        primeSources(now: now)

        for source in scenario.startsStopped {
            core.forceStopped(source)
        }
        if scenario.wakesOnApply {
            core.suspend(.sleep, now: now)
            core.resume(.sleep, now: now)
        }
        if scenario.startsPaused {
            core.setUserPaused(true, now: now)
        }
        changed()
    }

    public func useLiveData() {
        guard providerRouter.useLive() else { return }
        core.history.removeAll()
        core.resetState()
        core.rescheduleAll(at: Self.now)
        changed()
    }

    public func refreshDiskVolumes() {
        guard isLive else { return }
        core.diskVolumesDidChange(now: Self.now)
        if core.isCollecting, core.intervals[.disk] != nil { reschedule() }
    }

    public func refreshThermalStatus() {
        core.refresh(.thermal, now: Self.now)
        changed()
    }

    /// Opens sources slightly in the past and takes one sample, so values appear without a warm-up.
    private func primeSources(now: TimeInterval) {
        guard core.isCollecting else { return }
        core.rescheduleAll(at: now - 2)
        core.tick(now: now - 2)
        core.rescheduleAll(at: now)
        core.tick(now: now)
    }

    // MARK: Commands

    public func setUserPaused(_ paused: Bool) {
        core.setUserPaused(paused, now: Self.now)
        changed()
    }

    public func toggleUserPaused() {
        setUserPaused(!core.userPaused)
    }

    public func suspend(_ reason: SuspendReason) {
        core.suspend(reason, now: Self.now)
        changed()
    }

    public func resume(_ reason: SuspendReason) {
        core.resume(reason, now: Self.now)
        changed()
    }

    public func setDemand(_ demand: Demand, active: Bool) {
        guard core.demands.contains(demand) != active else { return }
        core.setDemand(demand, active: active, now: Self.now)
        changed()
    }

    public func setWindowPage(from old: Page?, to new: Page?) {
        guard old != new else { return }
        let wake = core.nextWakeTime()
        core.setWindowPage(from: old, to: new, now: Self.now)
        // The selection already redraws the view. Publishing a new snapshot
        // here advances every chart's time window without collecting a sample.
        if core.nextWakeTime() != wake { reschedule() }
    }

    public func setUserInterval(_ interval: UpdateInterval) {
        core.setUserInterval(interval.rawValue, now: Self.now)
        changed()
    }

    public func setNetworkInterface(_ name: String?) {
        core.setNetworkInterface(name, now: Self.now)
        changed()
    }

    public func setTemperatureSource(_ source: TemperatureSource) {
        core.setTemperatureSource(source, now: Self.now)
        changed()
    }

    public func retry(_ source: SourceID) {
        core.retry(source, now: Self.now)
        changed()
    }

    public func retryStopped() {
        let now = Self.now
        for source in SourceID.allCases where core.sources[source]?.phase == .stopped {
            core.retry(source, now: now)
        }
        changed()
    }

    public func recoveryEvent() {
        core.recoveryEvent(now: Self.now)
        changed()
    }

    // MARK: Debug controls

    public func setBehavior(_ behavior: SimulatedBehavior, for source: SourceID) {
        fixtures.setBehavior(behavior, for: source)
        changed()
    }

    public func forceStopped(_ source: SourceID) {
        core.forceStopped(source)
        changed()
    }

    public func setRecoveryTimeScale(_ scale: Double) {
        core.recoveryTimeScale = scale
    }

    public func setSensor(_ id: String, missing: Bool) {
        fixtures.setSensor(id, missing: missing)
        changed()
    }

    // MARK: Observation

    @discardableResult
    public func addObserver(_ handler: @escaping @MainActor (MonitorEngine) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = handler
        handler(self)
        return nextObserverID
    }

    public func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    private func changed() {
        publish()
        reschedule()
    }

    private func publish() {
        snapshot = core.snapshot(now: Self.now)
        for handler in observers.values {
            handler(self)
        }
    }

    private func reschedule() {
        loop?.cancel()
        loop = nil
        guard let first = core.nextWakeTime() else { return }
        loop = Task { [weak self] in
            var wake = first
            while !Task.isCancelled {
                let delay = wake - MonitorEngine.now
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(delay >= 1 ? 50 : 10))
                    } catch {
                        return
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.wakeCount += 1
                self.core.tick(now: MonitorEngine.now)
                self.publish()
                guard let next = self.core.nextWakeTime() else {
                    self.loop = nil
                    return
                }
                wake = next
            }
        }
    }
}
