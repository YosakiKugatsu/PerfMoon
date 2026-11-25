// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Keeps the UI contract stable while Debug review swaps live data for fixtures.
@MainActor
final class ProviderRouter: MetricProvider {
    let fixtures: FixtureProvider
    let live: (any MetricProvider)?
    private var current: any MetricProvider

    init(fixtures: FixtureProvider, live: (any MetricProvider)?) {
        self.fixtures = fixtures
        self.live = live
        self.current = live ?? fixtures
    }
    var machine: MachineInfo { current.machine }
    var sensors: [SensorInfo] { current.sensors }
    var throttleStatus: ThrottleStatus { current.throttleStatus }
    var gpuThrottleStatus: ThrottleStatus { current.gpuThrottleStatus }
    var processMemory: ProcessMemorySnapshot { current.processMemory }
    var isLive: Bool { current.isLive }
    var processBackgroundSample: (@MainActor (Double, Bool) async -> ProcessMemorySnapshot)? { current.processBackgroundSample }
    var preparesBatches: Bool { current.preparesBatches }
    func prepare(_ requests: [JobID: SampleRequest], at time: TimeInterval) { current.prepare(requests, at: time) }
    func selfUsage(at time: TimeInterval, window: TimeInterval) -> SelfUsage? { current.selfUsage(at: time, window: window) }
    func invalidateDiskDevices() { current.invalidateDiskDevices() }
    var diskBackgroundSample: (@Sendable (Double) -> SampleOutcome)? { current.diskBackgroundSample }
    func open(_ source: SourceID, at time: TimeInterval) -> OpenResult { current.open(source, at: time) }
    func close(_ source: SourceID) { current.close(source) }
    func rebaseline(_ source: SourceID, at time: TimeInterval) { current.rebaseline(source, at: time) }
    func sample(_ job: JobID, request: SampleRequest, at time: TimeInterval) -> SampleOutcome { current.sample(job, request: request, at: time) }
    func useFixtures() {
        for source in SourceID.allCases { current.close(source) }
        current = fixtures
    }
    func useLive() -> Bool {
        guard let live else { return false }
        for source in SourceID.allCases { current.close(source) }
        current = live
        return true
    }
}
