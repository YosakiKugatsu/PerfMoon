// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import PerfMoonKit

@MainActor
@Suite("Continuous chart history")
struct ContinuousHistoryTests {
    @Test("Closing and locking the window keeps every chart source alive on the existing background tick")
    func windowAndLock() {
        let core = MonitorCore(provider: FixtureProvider(scenario: .typical, anchor: 1000))
        core.setDemand(.continuousHistory, active: true, now: 1000)
        core.start(now: 1000)
        core.setTemperatureSource(.sensor("TB1T"), now: 1000)
        core.setDemand(.coreHistory, active: true, now: 1000)
        core.setWindowPage(from: nil, to: .cpu, now: 1000)
        for t in 1000...1005 { core.tick(now: Double(t)) }
        core.setWindowPage(from: .cpu, to: nil, now: 1005)
        core.setDemand(.coreHistory, active: false, now: 1005)
        core.discardCoreHistory()
        // A frontmost window or expanded list can still be present when the lock notification arrives.
        core.setWindowPage(from: nil, to: .cpu, now: 1005)
        core.setDemand(.windowMemoryProcesses, active: true, now: 1005)
        core.suspend(.screenLocked, now: 1005)
        for t in 1006...1014 { core.tick(now: Double(t)) }
        for job: JobID in [.cpuActivity, .energy, .corePower, .temperatures, .diskActivity, .network] {
            #expect(core.intervals[job] == 2)
        }
        for job: JobID in [.disk, .processMemory, .sensorCatalog, .selfUsage] { #expect(core.intervals[job] == nil) }
        let id = CoreID(flatIndex: 9)
        for key: SeriesKey in [.coreUsage(id), .coreTemperature(id), .corePower(id), .diskActivity(1, .readIOPS), .networkUpload, .cpuPower] {
            let samples = core.history.samples(key, since: 1004)
            #expect(samples.last?.time == 1014)
            #expect(samples.allSatisfy { !$0.startsSegment })
        }
        core.suspend(.sleep, now: 1015)
        #expect(!core.isCollecting)
        core.tick(now: 1100)
        core.resume(.sleep, now: 1101)
        for t in 1101...1106 { core.tick(now: Double(t)) }
        #expect(core.history.samples(.corePower(id), since: 1101).first?.startsSegment == true)
        core.setWindowPage(from: .cpu, to: nil, now: 1106)
        core.setDemand(.windowMemoryProcesses, active: false, now: 1106)
        core.setDemand(.continuousHistory, active: false, now: 1106)
        #expect(!core.isCollecting && core.intervals[.corePower] == nil)
        core.resume(.screenLocked, now: 1107)
        #expect(core.isCollecting)
    }

    @Test("Six hours preserve both extrema, the recent full-resolution tail, and actual breaks")
    func longWindows() throws {
        let h = HistoryStore()
        let key = SeriesKey.corePowerIndex(3)
        for t in 0...23_000 {
            if t == 9_012 { h.markBreak(key) }
            if (9_012..<9_050).contains(t) { continue }
            let value = t == 4_091 ? 5.7 : t == 4_092 ? 0.013 : 1.5
            h.append(key, time: Double(t), value: value, expectedInterval: 1)
        }
        let full = h.points(key, start: 1400, end: 23_000)
        #expect(full.count <= 190)
        #expect(full.first!.time >= 1400 && full.first!.time < 1430)
        #expect(full.last?.time == 23_000)
        #expect(full.contains { $0.time == 4091 && abs($0.value - 5.7) < 0.001 })
        #expect(full.contains { $0.time == 4092 && abs($0.value - 0.013) < 0.0001 })
        #expect(Set(full.map(\.segment)).count == 2)
        #expect(full.first { $0.time >= 9050 }?.segment == 1)
        #expect(h.samples(key, since: 22_100).count == 901)
        #expect(h.points(key, start: 19_400, end: 23_000).allSatisfy { $0.segment == 0 && $0.time >= 19_400 })
        h.remove(key)
        #expect(h.points(key, start: 0, end: 23_000).isEmpty)
    }

    @Test("A one-second pressure spike and a genuine gap survive a six-hour chart")
    func discreteTransitions() {
        let h = HistoryStore()
        for t in 0...22_000 {
            if t == 5_001 { h.markBreak(.memoryPressure) }
            if (5_001..<5_040).contains(t) { continue }
            h.append(.memoryPressure, time: Double(t), value: t == 4090 ? 2 : 0, expectedInterval: 1)
        }
        let runs = h.runs(.memoryPressure, start: 400, end: 22_000)
        #expect(runs.map(\.level) == [0, 2, 0, 0])
        #expect(runs.map(\.start) == [400, 4090, 4091, 5040])
        #expect(runs.map(\.end) == [4090, 4091, 5001, 22_000])
        #expect(runs.first?.segment != runs.last?.segment)
    }

    @Test("Compact core cells carry their own units, switching when milliwatts would round to three digits")
    func compactPower() {
        #expect(Format.coreWatts(0, compact: true) == "0mW")
        #expect(Format.coreWatts(0.039, compact: true) == "39mW")
        #expect(Format.coreWatts(0.0994, compact: true) == "99mW")
        #expect(Format.coreWatts(0.1, compact: true) == "0.1W")
        #expect(Format.coreWatts(0.358, compact: true) == "0.4W")
        #expect(Format.coreWatts(0.358, compact: false) == "358 mW")
    }
}
