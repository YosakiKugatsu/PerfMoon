import Foundation
import Testing
@testable import PerfMoonKit

@Suite("Live-data contracts")
struct NativeBehaviorTests {
    @Test("A low clock or isolated throttle counter does not prove thermal throttling")
    func conservativeThermalEvidence() {
        #expect(!ThermalPolicy.evaluate(thermalState: 0, cpuLimitPercent: 50, hardwareThrottleRecent: true).isActive)
        #expect(!ThermalPolicy.evaluate(thermalState: 2, cpuLimitPercent: nil, hardwareThrottleRecent: false).isActive)
        #expect(ThermalPolicy.evaluate(thermalState: 2, cpuLimitPercent: nil, hardwareThrottleRecent: true).isActive)
        #expect(ThermalPolicy.evaluate(thermalState: 1, cpuLimitPercent: 75, hardwareThrottleRecent: false).isActive)
        #expect(ThermalPolicy.evaluate(thermalState: 3, cpuLimitPercent: nil, hardwareThrottleRecent: false).isActive)
    }

    @Test("Process scans are absent in background and a collapsed popover")
    func onDemandProcesses() {
        #expect(SchedulePlanner.intervals(userInterval: 1, demands: [])[.processMemory] == nil)
        #expect(SchedulePlanner.intervals(userInterval: 1, demands: [.popover])[.processMemory] == nil)
        #expect(SchedulePlanner.intervals(userInterval: 1, demands: [.memoryProcesses])[.processMemory] == 5)
        #expect(SchedulePlanner.intervals(userInterval: 1, demands: [.window(.memory)])[.processMemory] == 5)
        #expect(SchedulePlanner.intervals(userInterval: 5, demands: [.window(.cpu)])[.processMemory] == nil)
    }

    @MainActor
    @Test("A provider's measured window survives scheduling and snapshot construction")
    func measuredWindow() {
        let source = MeasuredProvider()
        let core = MonitorCore(provider: source)
        core.start(now: 100)
        core.tick(now: 100)
        core.tick(now: 102)
        #expect(core.reading(.cpuTotal).window == 2.37)
        #expect(core.reading(.cpuTotal).value == 7)
    }

    @MainActor
    @Test("Mode changes refresh sensor identities and returning live preserves user pause")
    func providerSwitch() {
        let fixtures = FixtureProvider()
        let engine = MonitorEngine(fixtures: fixtures, liveProvider: MeasuredProvider())
        #expect(engine.isLive)
        #expect(engine.core.sensorInfo("TEST") != nil)
        engine.apply(scenario: .typical)
        #expect(!engine.isLive)
        #expect(engine.core.sensorInfo("TEST") == nil)
        engine.setUserPaused(true)
        engine.useLiveData()
        #expect(engine.isLive)
        #expect(engine.core.sensorInfo("TEST") != nil)
        #expect(engine.core.userPaused)
    }
}

@MainActor
private final class MeasuredProvider: MetricProvider {
    let machine = MachineInfo(chipName: "Test", shortChipName: "Test", gpuCoreCount: 20, physicalMemory: 64 * 1024 * 1024 * 1024)
    let sensors = [SensorInfo(id: "TEST", name: "Test Sensor", category: .other)]
    var isLive: Bool { true }
    func open(_ source: SourceID, at time: TimeInterval) -> OpenResult { .opened }
    func close(_ source: SourceID) {}
    func rebaseline(_ source: SourceID, at time: TimeInterval) {}
    func sample(_ job: JobID, request: SampleRequest, at time: TimeInterval) -> SampleOutcome {
        .measured(Dictionary(uniqueKeysWithValues: job.keys.map { ($0, 7.0) }), window: 2.37)
    }
}
