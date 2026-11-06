import Testing
@testable import PerfMoonKit

@MainActor
@Suite("Per-core history")
struct CoreHistoryTests {
    private func makeCore(recordHistory: Bool = true) -> (MonitorCore, FixtureProvider) {
        let provider = FixtureProvider(scenario: .singleCoreSaturated, anchor: 1000)
        let core = MonitorCore(provider: provider)
        core.setUserInterval(2, now: 1000)
        core.setDemand(.coreHistory, active: recordHistory, now: 1000)
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
    @Test("Background and popover preserve aggregate history and current cores without per-core buffers")
    func backgroundHistoryIsAbsent() {
        let (background, _) = makeCore(recordHistory: false)
        let (visible, _) = makeCore()
        advance(background, until: 1040)
        advance(visible, until: 1040)
        #expect(background.sampleCount == visible.sampleCount)
        #expect(background.intervals == visible.intervals)
        for key in SeriesKey.allCases where !key.isPerCore {
            #expect(background.history.samples(key, since: 0) == visible.history.samples(key, since: 0))
        }
        background.setDemand(.popover, active: true, now: 1040)
        advance(background, until: 1050)
        for id in CoreID.all {
            #expect(background.reading(.core(id.flatIndex)).status == .valid)
            #expect(background.history.series(.coreUsage(id)) == nil)
            #expect(background.history.series(.coreTemperature(id)) == nil)
        }
        #expect(background.history.last(.gpuPower)?.time == 1050)
        // Pause/failure breaks must not allocate absent series.
        background.setUserPaused(true, now: 1051)
        #expect(SeriesKey.allCases.filter(\.isPerCore).allSatisfy { background.history.series($0) == nil })
    }

    @Test("Main-window visibility releases buffers and reopening starts new history")
    func visibilityLifecycle() {
        let (core, _) = makeCore(recordHistory: false)
        advance(core, until: 1010)
        core.setDemand(.coreHistory, active: true, now: 1011)
        core.setDemand(.window(.cpu), active: true, now: 1011)
        advance(core, until: 1018)
        let first = core.history.count(.coreUsage(CoreID(flatIndex: 0)))
        #expect(first > 0)
        core.setDemand(.window(.cpu), active: false, now: 1019)
        core.setDemand(.window(.memory), active: true, now: 1019)
        #expect(core.history.count(.coreUsage(CoreID(flatIndex: 0))) == first)
        advance(core, until: 1022)
        core.setDemand(.coreHistory, active: false, now: 1023)
        let pausedCount = core.history.count(.coreUsage(CoreID(flatIndex: 0)))
        advance(core, until: 1030)
        #expect(core.history.count(.coreUsage(CoreID(flatIndex: 0))) == pausedCount)
        core.discardCoreHistory()
        #expect(SeriesKey.allCases.filter(\.isPerCore).allSatisfy { core.history.series($0) == nil })
        advance(core, until: 1040)
        core.setDemand(.coreHistory, active: true, now: 1041)
        advance(core, until: 1044)
        for id in CoreID.all {
            let samples = core.history.samples(.coreUsage(id), since: 0)
            #expect(samples.first?.time == 1042)
            #expect(samples.first?.startsSegment == true)
            #expect(samples.count == 2)
        }
    }

}
