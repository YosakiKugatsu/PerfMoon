// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Testing
@testable import PerfMoonKit

@Suite("Schedule planner")
struct PlannerTests {
    @Test("Background runs at max(interval, 2 s); temperatures at max(interval, 2 s)")
    func background() {
        let one = SchedulePlanner.intervals(userInterval: 1, demands: [])
        #expect(one[.cpuActivity] == 2)
        #expect(one[.temperatures] == 2)
        #expect(one[.sensorCatalog] == nil)
        #expect(one[.selfUsage] == nil)

        let five = SchedulePlanner.intervals(userInterval: 5, demands: [])
        #expect(five[.cpuActivity] == 5)
        #expect(five[.temperatures] == 5)
    }

    @Test("Visible surfaces raise only the jobs they show to the user interval")
    func visible() {
        let popover = SchedulePlanner.intervals(userInterval: 1, demands: [.popover])
        #expect(popover[.cpuActivity] == 1)
        #expect(popover[.memory] == 1)
        #expect(popover[.temperatures] == 2)

        let memoryPage = SchedulePlanner.intervals(userInterval: 1, demands: [.window(.memory)])
        #expect(memoryPage[.memory] == 1)
        #expect(memoryPage[.memoryPressure] == 1)
        #expect(memoryPage[.cpuActivity] == 2)
    }

    @Test("Sensor table preview and self usage only run while visible")
    func onDemand() {
        let intervals = SchedulePlanner.intervals(userInterval: 1, demands: [.sensorTable, .performancePage])
        #expect(intervals[.sensorCatalog] == 5)
        #expect(intervals[.selfUsage] == 10)
        let slow = SchedulePlanner.intervals(userInterval: 5, demands: [.sensorTable])
        #expect(slow[.sensorCatalog] == 5)
    }

    @Test("Thermal polling joins regular ticks without extending its latency")
    func alignedThermalPolling() {
        for interval in [1.0, 2.0, 5.0] {
            for demands: Set<Demand> in [[], [.popover]] {
                let plan = SchedulePlanner.intervals(userInterval: interval, demands: demands)
                let cadence = plan.values.min()!
                let thermal = plan[.thermal]!
                #expect(thermal.truncatingRemainder(dividingBy: cadence) == 0)
                #expect(thermal <= max(interval, 5))
            }
        }
    }
}

@MainActor
@Suite("Monitor core")
struct MonitorCoreTests {
    func makeCore(_ scenario: FixtureScenario = .typical) -> (MonitorCore, FixtureProvider) {
        let provider = FixtureProvider(scenario: scenario, anchor: 1000)
        let core = MonitorCore(provider: provider)
        core.start(now: 1000)
        return (core, provider)
    }

    /// Ticks at every wake time up to `end`.
    func run(_ core: MonitorCore, until end: Double) {
        while let next = core.nextWakeTime(), next <= end {
            core.tick(now: next)
        }
    }

    @Test("Disk capacity refreshes only for visible consumers and freezes while paused")
    func diskCapacityDemand() {
        let (core, _) = makeCore()
        core.setDemand(.window(.memory), active: true, now: 1000)
        run(core, until: 1004)
        #expect(core.intervals[.disk] == nil)
        #expect(core.snapshot(now: 1004).disk.usedFraction == nil)

        core.setDemand(.window(.overview), active: true, now: 1004)
        run(core, until: 1004)
        let first = core.snapshot(now: 1004).disk
        #expect(first.totalBytes == 1_000_000_000_000)
        #expect(first.used.shownValue == 380_000_000_000)
        #expect(first.usedFraction == nil) // APFS volume bytes do not own the container capacity.
        #expect(core.snapshot(now: 1004).diskDrives.first?.usedFraction == 0.38)
        #expect(first.used.timestamp == 1004)

        core.setDemand(.popover, active: true, now: 1005)
        core.setDemand(.window(.overview), active: false, now: 1005)
        run(core, until: 1029)
        #expect(core.snapshot(now: 1029).disk == first)
        run(core, until: 1030)
        #expect(core.snapshot(now: 1030).disk.used.timestamp == 1030)

        core.setDemand(.popover, active: false, now: 1031)
        run(core, until: 1060)
        #expect(core.nextDue[.disk] == nil)
        #expect(core.snapshot(now: 1060).disk.used.timestamp == 1030)

        core.setUserPaused(true, now: 1061)
        core.setDemand(.window(.disk), active: true, now: 1062)
        core.tick(now: 1062)
        #expect(core.snapshot(now: 1062).disk.used.timestamp == 1030)
        core.setUserPaused(false, now: 1063)
        run(core, until: 1063)
        #expect(core.snapshot(now: 1063).disk.used.timestamp == 1063)
    }

    @Test("Background collection has no thermal-only wake between two-second ticks")
    func backgroundWakeGrid() {
        let (core, _) = makeCore()
        var wakes: [Double] = []
        while let next = core.nextWakeTime(), next <= 1010 {
            wakes.append(next)
            core.tick(now: next)
        }
        #expect(wakes == [1000, 1002, 1004, 1006, 1008, 1010])
        #expect(core.reading(.cpuTotal).status == .valid)
        #expect(core.history.count(.cpuTotal) == 5)
    }

    @Test("Differenced metrics show one warm-up cycle after the first subscription")
    func firstWarmup() {
        let (core, _) = makeCore()
        core.tick(now: 1000)
        #expect(core.reading(.cpuTotal).status == .warming)
        #expect(core.reading(.memoryUsed).status == .valid)
        #expect(core.reading(.pageIns).status == .warming)
        run(core, until: 1002)
        #expect(core.reading(.cpuTotal).status == .valid)
        #expect(core.reading(.pageIns).status == .valid)
    }

    @Test("Pause stops all sampling and the run loop; history breaks at the pause")
    func pauseStopsCollection() {
        let (core, _) = makeCore()
        run(core, until: 1010)
        let samplesBefore = core.sampleCount
        core.setUserPaused(true, now: 1010.5)
        #expect(core.nextWakeTime() == nil)
        core.tick(now: 1020)
        #expect(core.sampleCount == samplesBefore)

        core.setUserPaused(false, now: 1030)
        #expect(core.reading(.cpuTotal).status == .warming)
        run(core, until: 1034)
        #expect(core.reading(.cpuTotal).status == .valid)
        let samples = core.history.samples(.cpuTotal, since: 1029)
        #expect(samples.first?.startsSegment == true)
    }

    @Test("Waking from sleep never cancels a user pause")
    func wakeKeepsPause() {
        let (core, _) = makeCore()
        run(core, until: 1004)
        core.setUserPaused(true, now: 1005)
        core.suspend(.sleep, now: 1006)
        core.resume(.sleep, now: 1100)
        #expect(core.userPaused)
        #expect(!core.isCollecting)
        #expect(core.nextWakeTime() == nil)
    }

    @Test("Sleep without a pause resumes with a gap and a warm-up cycle")
    func wakeResumes() {
        let (core, _) = makeCore()
        run(core, until: 1004)
        core.suspend(.sleep, now: 1004.5)
        #expect(core.nextWakeTime() == nil)
        core.resume(.sleep, now: 1200)
        #expect(core.isCollecting)
        #expect(core.reading(.cpuTotal).status == .warming)
        run(core, until: 1203)
        let after = core.history.samples(.cpuTotal, since: 1100)
        #expect(after.first?.startsSegment == true)
    }

    @Test("Changing the temperature source clears its series instead of relabeling it")
    func sourceReplacement() {
        let (core, _) = makeCore()
        run(core, until: 1020)
        #expect(core.history.count(.cpuTemperature) > 0)
        core.setTemperatureSource(.sensor("TB1T"), now: 1020.5)
        #expect(core.history.count(.cpuTemperature) == 0)
        run(core, until: 1024)
        #expect(core.reading(.cpuTemperature).status == .valid)
        #expect(core.history.count(.cpuTemperature) > 0)
        #expect(core.history.samples(.cpuTemperature, since: 0).allSatisfy { $0.value < 40 })
    }

    @Test("Transient failures back off 1, 2, 4, 8, 16, 30 s and then stop")
    func backoff() {
        let (core, provider) = makeCore()
        run(core, until: 1004)
        provider.setBehavior(.failing, for: .energy)
        // Energy samples every 2 s in the background; the 1006 sample fails.
        run(core, until: 1006)
        guard case .recovering(0, let first) = core.sources[.energy]?.phase else {
            Issue.record("expected recovery")
            return
        }
        #expect(core.reading(.cpuPower).unavailableReason == .retrying)

        #expect(first == 1007)
        var attemptTimes: [Double] = []
        var previous = provider.failedOpens[.energy] ?? 0
        var time = first - 1
        while time < first + 120 {
            time += 0.5
            core.tick(now: time)
            let count = provider.failedOpens[.energy] ?? 0
            if count != previous { attemptTimes.append(time); previous = count }
        }
        let gaps = zip(attemptTimes, attemptTimes.dropFirst()).map { $1 - $0 }
        #expect(attemptTimes.count == 6)
        #expect(gaps == [2, 4, 8, 16, 30])
        #expect(core.sources[.energy]?.phase == .stopped)
        #expect(core.reading(.cpuPower).unavailableReason == .stopped)
        // Other sources are unaffected.
        #expect(core.reading(.cpuTotal).status == .valid)
        #expect(core.prompt() == .retry([.energy]))
    }

    @Test("Unsupported sources are never polled")
    func unsupportedNotPolled() {
        let (core, provider) = makeCore()
        provider.setBehavior(.unsupported, for: .gpuActivity)
        run(core, until: 1010)
        let generation = provider.generations[.gpuActivity] ?? 0
        run(core, until: 1200)
        #expect(provider.generations[.gpuActivity] ?? 0 == generation)
        #expect(core.reading(.gpuUsage).unavailableReason == .unsupported)
        #expect(core.prompt() == nil)
    }

    @Test("Manual Retry rebuilds the subscription and warms up for one cycle")
    func manualRetry() {
        let (core, provider) = makeCore()
        run(core, until: 1004)
        core.forceStopped(.energy)
        #expect(!provider.openSources.contains(.energy))
        let generation = provider.generations[.energy] ?? 0
        core.retry(.energy, now: 1005)
        #expect(provider.generations[.energy] == generation + 1)
        #expect(core.reading(.cpuPower).status == .warming)
        run(core, until: 1008)
        #expect(core.reading(.cpuPower).status == .valid)
    }

    @Test("A missing selected sensor keeps the selection and offers CPU Max")
    func missingSensorPrompt() {
        let (core, provider) = makeCore()
        core.setTemperatureSource(.sensor("Tp0X"), now: 1000)
        run(core, until: 1004)
        provider.setSensor("Tp0X", missing: true)
        run(core, until: 1008)
        #expect(core.temperatureSource == .sensor("Tp0X"))
        #expect(core.reading(.cpuTemperature).unavailableReason == .sensorMissing)
        #expect(core.prompt() == .useCPUMax(sensorID: "Tp0X"))

        // A stopped source takes priority over the sensor prompt.
        core.forceStopped(.energy)
        #expect(core.prompt() == .retry([.energy]))
    }

    @Test("Readings go stale after three expected cycles without new data")
    func stale() {
        let (core, provider) = makeCore()
        run(core, until: 1006)
        provider.setBehavior(.stale, for: .memoryPressure)
        run(core, until: 1008)
        #expect(core.reading(.memoryPressure).status == .valid)
        run(core, until: 1016)
        #expect(core.reading(.memoryPressure).status == .stale)
    }

    @Test("Zero is a valid reading")
    func zeroIsValid() {
        let (core, _) = makeCore(.idle)
        run(core, until: 1006)
        #expect(core.reading(.anePower).status == .valid)
        #expect(core.reading(.anePower).value == 0)
    }

    @Test("The sensor table preview reads all sensors only while visible")
    func catalogOnDemand() {
        let (core, _) = makeCore()
        run(core, until: 1006)
        #expect(core.catalog.isEmpty)
        core.setDemand(.sensorTable, active: true, now: 1006)
        run(core, until: 1007)
        #expect(core.catalog.count == core.sensors.count)
        core.setDemand(.sensorTable, active: false, now: 1007)
        #expect(core.intervals[.sensorCatalog] == nil)
    }

    @Test("The one S-Core fixture yields 100% / 16.7% / 5.6%")
    func singleCoreFixture() {
        let (core, _) = makeCore(.singleCoreSaturated)
        run(core, until: 1006)
        #expect(core.reading(.core(0)).value == 100)
        #expect(abs((core.reading(.cpuS).value ?? 0) - 16.67) < 0.01)
        #expect(abs((core.reading(.cpuTotal).value ?? 0) - 5.56) < 0.01)
    }
}
