// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

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
        #expect(!ThermalPolicy.evaluateGPU(thermalState: 0, hardwareThrottleRecent: true, hardwareAvailable: true).isActive)
        #expect(!ThermalPolicy.evaluateGPU(thermalState: 2, hardwareThrottleRecent: false, hardwareAvailable: true).isActive)
        #expect(ThermalPolicy.evaluateGPU(thermalState: 2, hardwareThrottleRecent: true, hardwareAvailable: true).isActive)
        #expect(!ThermalPolicy.evaluateGPU(thermalState: 1, hardwareThrottleRecent: false, hardwareAvailable: false).isAvailable)
        #expect(ThermalPolicy.evaluateGPU(thermalState: 3, hardwareThrottleRecent: false, hardwareAvailable: false).isActive)
    }

    @MainActor
    @Test("CPU and GPU throttling remain independent across the UI data contract")
    func independentThrottleStatuses() {
        let provider = MeasuredProvider()
        let core = MonitorCore(provider: provider)
        provider.throttleStatus = ThrottleStatus(isActive: true)
        provider.gpuThrottleStatus = .normal
        #expect(core.snapshot(now: 100).cpu.throttle.isActive)
        #expect(!core.snapshot(now: 100).gpu.throttle.isActive)
        provider.throttleStatus = .normal
        provider.gpuThrottleStatus = ThrottleStatus(isActive: true)
        #expect(!core.snapshot(now: 101).cpu.throttle.isActive)
        #expect(core.snapshot(now: 101).gpu.throttle.isActive)
        provider.gpuThrottleStatus = .unavailable
        #expect(!core.snapshot(now: 102).gpu.throttle.isAvailable)
    }

    @Test("Process scans are absent in background and a collapsed popover")
    func onDemandProcesses() {
        #expect(SchedulePlanner.intervals(userInterval: 1, demands: [])[.processMemory] == nil)
        #expect(SchedulePlanner.intervals(userInterval: 1, demands: [.popover])[.processMemory] == nil)
        #expect(SchedulePlanner.intervals(userInterval: 1, demands: [.memoryProcesses])[.processMemory] == 5)
        #expect(SchedulePlanner.intervals(userInterval: 1, demands: [.window(.memory)])[.processMemory] == nil)
        #expect(SchedulePlanner.intervals(userInterval: 5, demands: [.window(.cpu)])[.processMemory] == nil)
    }

    @MainActor
    @Test("Independent Top 10 consumers share one scan and reopen with fresh data")
    func processDemandUnion() {
        let provider = FixtureProvider(scenario: .typical, anchor: 1000)
        let core = MonitorCore(provider: provider)
        core.start(now: 1000)
        core.setDemand(.window(.memory), active: true, now: 1000)
        core.tick(now: 1000)
        #expect(core.intervals[.processMemory] == nil)
        core.setDemand(.memoryProcesses, active: true, now: 1001)
        core.tick(now: 1001)
        #expect(core.snapshot(now: 1001).memory.processes.status == .valid)
        core.setDemand(.windowMemoryProcesses, active: true, now: 1002)
        let due = core.nextDue[.processMemory]
        core.setDemand(.memoryProcesses, active: false, now: 1003)
        #expect(core.nextDue[.processMemory] == due)
        #expect(core.intervals[.processMemory] == 5)
        core.setDemand(.windowMemoryProcesses, active: false, now: 1004)
        #expect(core.intervals[.processMemory] == nil)
        core.setDemand(.windowMemoryProcesses, active: true, now: 1020)
        #expect(core.snapshot(now: 1020).memory.processes.status == .warming)
        core.tick(now: 1020)
        #expect(core.snapshot(now: 1020).memory.processes.timestamp == 1020)
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
    var throttleStatus: ThrottleStatus = .normal
    var gpuThrottleStatus: ThrottleStatus = .normal
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
