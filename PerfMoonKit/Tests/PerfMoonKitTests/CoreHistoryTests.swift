import Testing
@testable import PerfMoonKit

@MainActor
@Suite("Per-core history")
struct CoreHistoryTests {
    private func makeCore() -> (MonitorCore, FixtureProvider) {
        let provider = FixtureProvider(scenario: .singleCoreSaturated, anchor: 1000)
        let core = MonitorCore(provider: provider)
        core.setUserInterval(2, now: 1000)
        core.start(now: 1000)
        return (core, provider)
    }

    private func advance(_ core: MonitorCore, until end: Double) {
        while let next = core.nextWakeTime(), next <= end { core.tick(now: next) }
    }

    @Test("Every core keeps its own observed usage and mapped temperature without extra jobs")
    func recordsDistinctCores() {
        let (core, _) = makeCore()
        core.tick(now: 1000)
        #expect(CoreID.all.allSatisfy { core.history.count(.coreUsage($0)) == 0 })
        advance(core, until: 1010)

        #expect(Set(CoreID.all.map(SeriesKey.coreUsage)).count == CoreID.count)
        #expect(Set(CoreID.all.map(SeriesKey.coreTemperature)).count == CoreID.count)
        for id in CoreID.all {
            let usage = core.history.last(.coreUsage(id))
            let temperature = core.history.last(.coreTemperature(id))
            #expect(usage?.value == core.reading(.core(id.flatIndex)).value.map(Float.init))
            #expect(temperature?.value == core.reading(.coreTemperature(id.flatIndex)).value.map(Float.init))
            #expect(usage?.time == 1010)
            #expect(temperature?.time == 1010)
            #expect(core.history.count(.coreUsage(id)) == core.history.count(.cpuTotal))
            #expect(SeriesKey.coreUsage(id).source == .cpuActivity)
            #expect(SeriesKey.coreTemperature(id).source == .sensors)
        }
        #expect(core.history.last(.coreUsage(CoreID(flatIndex: 0)))?.value == 100)
        #expect(core.intervals == SchedulePlanner.intervals(userInterval: 2, demands: []))
        // Six two-second ticks of nine regular jobs, plus three thermal polls.
        #expect(core.sampleCount == 57)
    }

    @Test("A missing mapped sensor leaves a gap in only that core's temperature")
    func missingSensorGap() throws {
        let (core, provider) = makeCore()
        advance(core, until: 1006)
        let id = CoreID(flatIndex: 0)
        let neighbor = CoreID(flatIndex: 1)
        let sensor = try #require(core.mappedSensor(for: id))
        let before = core.history.count(.coreTemperature(id))
        provider.setSensor(sensor, missing: true)
        advance(core, until: 1010)
        #expect(core.history.count(.coreTemperature(id)) == before)
        #expect(core.history.last(.coreTemperature(neighbor))?.time == 1010)
        #expect(core.history.last(.coreUsage(id))?.time == 1010)
        provider.setSensor(sensor, missing: false)
        advance(core, until: 1012)
        #expect(core.history.last(.coreTemperature(id))?.startsSegment == true)
        #expect(core.history.last(.coreTemperature(id))?.time == 1012)
    }

    @Test("Custom CPU sources do not fill uncollected core temperatures with old values")
    func customSourceLeavesHonestHistory() {
        let (core, _) = makeCore()
        advance(core, until: 1006)
        let id = CoreID(flatIndex: 0)
        let before = core.history.count(.coreTemperature(id))
        core.setTemperatureSource(.sensor("TB1T"), now: 1007)
        advance(core, until: 1020)
        #expect(core.history.count(.coreTemperature(id)) == before)
        #expect(core.history.last(.coreUsage(id))?.time == 1020)
        core.setDemand(.window(.cpu), active: true, now: 1020)
        advance(core, until: 1024)
        let fresh = core.history.samples(.coreTemperature(id), since: 1020)
        #expect(fresh.first?.startsSegment == true)
        #expect(fresh.last?.time == 1024)
        #expect(core.intervals[.temperatures] == 2)
    }

    @Test("Pause preserves all per-core histories and resumes them with explicit breaks")
    func pauseAndResume() {
        let (core, _) = makeCore()
        advance(core, until: 1006)
        let before = core.sampleCount
        core.setUserPaused(true, now: 1007)
        core.tick(now: 1030)
        #expect(core.sampleCount == before)
        core.setUserPaused(false, now: 1031)
        advance(core, until: 1036)
        for id in CoreID.all {
            #expect(core.history.samples(.coreUsage(id), since: 1030).first?.startsSegment == true)
            #expect(core.history.samples(.coreTemperature(id), since: 1030).first?.startsSegment == true)
        }
    }

    @Test("Preview histories include each mapped core and obey unsupported-source states")
    func fixtureHistory() {
        let history = HistoryStore()
        let provider = FixtureProvider(scenario: .typical, anchor: 1000)
        provider.prefill(history, now: 1000, temperatureSource: .cpuMax)
        for id in CoreID.all {
            #expect(history.count(.coreUsage(id)) > 0)
            #expect(history.count(.coreTemperature(id)) > 0)
            #expect(history.count(.coreUsage(id)) <= 1024)
            #expect(history.count(.coreTemperature(id)) <= 1024)
        }
        history.removeAll()
        provider.setBehavior(.unsupported, for: .sensors)
        provider.prefill(history, now: 1000, temperatureSource: .cpuMax)
        #expect(CoreID.all.allSatisfy { history.count(.coreTemperature($0)) == 0 })
        #expect(CoreID.all.allSatisfy { history.count(.coreUsage($0)) > 0 })
    }
}
