// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Testing
@testable import PerfMoonKit

@Suite("Mach CPU counter accounting")
struct CPUCounterTests {
    private func read(_ values: [UInt32], cpuCount: Int = 18, into sampler: inout CPUUsageAccumulator, at time: Double) -> CPUUsageAccumulator.Value? {
        values.map { Int32(bitPattern: $0) }.withUnsafeBufferPointer { sampler.sample($0, cpuCount: cpuCount, at: time) }
    }

    @Test("A single busy S-Core has correct physical order and weighted totals")
    func oneSuperCore() throws {
        var sampler = CPUUsageAccumulator(topology: .fixture)
        var values = [UInt32](repeating: 0, count: 72)
        #expect(read(values, into: &sampler, at: 100) == nil)
        for cpu in 0..<18 { values[cpu * 4 + 2] = 100 }
        values[12 * 4] = 100; values[12 * 4 + 2] = 0
        let result = try #require(read(values, into: &sampler, at: 102.25))
        #expect(result.cores[0] == 100)
        #expect(result.cores.dropFirst().allSatisfy { $0 == 0 })
        #expect(abs(try #require(result.sCore) - 100.0 / 6) < 1e-9)
        #expect(result.pCore == 0)
        #expect(abs(result.total - 100.0 / 18) < 1e-9)
        #expect(result.window == 2.25)
    }

    @Test("Both ends of the two core groups map to their own UI indices")
    func groupMapping() throws {
        var sampler = CPUUsageAccumulator(topology: .fixture)
        var values = [UInt32](repeating: 0, count: 72)
        _ = read(values, into: &sampler, at: 1)
        for cpu in 0..<18 { values[cpu * 4 + 2] = 100 }
        for (cpu, busy) in [(0, UInt32(50)), (12, UInt32(20)), (17, UInt32(90))] {
            values[cpu * 4] = busy; values[cpu * 4 + 2] = 100 - busy
        }
        let result = try #require(read(values, into: &sampler, at: 2))
        #expect(result.cores[6] == 50)
        #expect(result.cores[0] == 20)
        #expect(result.cores[5] == 90)
        #expect(abs(result.total - 160.0 / 18) < 1e-9)
    }

    @Test("Wrapping 32-bit Mach counters remain bounded and retain the ratio")
    func wraparound() throws {
        var sampler = CPUUsageAccumulator(topology: .fixture)
        var values = [UInt32](repeating: 0, count: 72)
        for cpu in 0..<18 { values[cpu * 4] = .max - 4; values[cpu * 4 + 2] = .max - 4 }
        _ = read(values, into: &sampler, at: 1)
        for cpu in 0..<18 { values[cpu * 4] = 3; values[cpu * 4 + 2] = 11 }
        let result = try #require(read(values, into: &sampler, at: 2))
        #expect(result.cores.allSatisfy { abs($0 - 100.0 / 3) < 1e-9 })
    }

    @Test("Reset, non-advancing time, and malformed input never reuse stale deltas")
    func resets() throws {
        var sampler = CPUUsageAccumulator(topology: .fixture)
        let values = [UInt32](repeating: 1000, count: 72)
        _ = read(values, into: &sampler, at: 10)
        #expect(read(values, into: &sampler, at: 9) == nil)
        let idle = try #require(read(values, into: &sampler, at: 10))
        #expect(idle.total == 0)
        sampler.reset()
        #expect(read(values, into: &sampler, at: 20) == nil)
        #expect(read(Array(values.prefix(71)), into: &sampler, at: 21) == nil)
        #expect(read(values, into: &sampler, at: 22) == nil)
        #expect(try #require(read(values, into: &sampler, at: 23)).total == 0)
    }

    @Test("Old efficiency and performance tiers follow kernel IDs, not contiguous slices")
    func efficiencyAndPerformance() throws {
        let topology = CPUTopology(logicalCPUCount: 4, performanceLevels: [("Performance", 2), ("Efficiency", 2)],
                                   firmwareTypes: [0: "P", 1: "E", 2: "P", 3: "E"])
        #expect(topology.clusters.map(\.title) == ["P-Core", "E-Core"])
        #expect(topology.cores.map(\.label) == ["E0", "E1", "P0", "P1"])
        #expect(topology.cores.map(\.machIndex) == [1, 3, 0, 2])
        var sampler = CPUUsageAccumulator(topology: topology)
        let work: [UInt32] = [20, 100, 40, 80]
        _ = read(Array(repeating: 0, count: 16), cpuCount: 4, into: &sampler, at: 1)
        let delta: [UInt32] = work.flatMap { [$0, 0, 100 - $0, 0] }
        let result = try #require(read(delta, cpuCount: 4, into: &sampler, at: 2))
        #expect(result.cores == [100, 80, 20, 40])
        #expect(result.eCore == 90)
        #expect(result.sCore == nil)
        #expect(result.pCore == 30)
        #expect(result.total == 60)
    }

    @Test("M5 Pro 15-core tags follow the named five-super, ten-performance layout")
    func fifteenCoreSuperTopology() {
        let tags = Dictionary(uniqueKeysWithValues: (0..<15).map { ($0, $0 < 10 ? "M" : "P") })
        let topology = CPUTopology(logicalCPUCount: 15, performanceLevels: [("Super", 5), ("Performance", 10)],
                                   firmwareTypes: tags)
        #expect(topology.clusters.map(\.title) == ["S-Core", "P-Core"])
        #expect(topology.clusters.map(\.count) == [5, 10])
        #expect(topology.core(atFlatIndex: 0)?.machIndex == 10)
        #expect(topology.core(atFlatIndex: 5)?.machIndex == 0)
        #expect(topology.core(atFlatIndex: 14)?.machIndex == 9)
    }

    @Test("Base M5 keeps six efficiency cores and four super cores in separate display slots")
    func baseM5Topology() throws {
        let superCPUs = Set([1, 4, 7, 9])
        let tags = Dictionary(uniqueKeysWithValues: (0..<10).map { ($0, superCPUs.contains($0) ? "P" : "E") })
        let topology = CPUTopology(logicalCPUCount: 10, performanceLevels: [("Super", 4), ("Efficiency", 6)],
                                   firmwareTypes: tags)
        #expect(topology.clusters.map(\.title) == ["S-Core", "E-Core"])
        #expect(topology.clusters.map(\.count) == [4, 6])
        #expect(topology.cluster(.e)?.cores.map(\.machIndex) == [0, 2, 3, 5, 6, 8])
        #expect(topology.cluster(.s)?.cores.map(\.machIndex) == [1, 4, 7, 9])
        #expect(topology.cluster(.p) == nil)
        #expect(topology.core(atFlatIndex: 6)?.label == "S0")

        var sampler = CPUUsageAccumulator(topology: topology)
        _ = read(Array(repeating: 0, count: 40), cpuCount: 10, into: &sampler, at: 1)
        let delta: [UInt32] = (0..<10).flatMap { superCPUs.contains($0) ? [100, 0, 0, 0] : [0, 0, 100, 0] }
        let result = try #require(read(delta, cpuCount: 10, into: &sampler, at: 2))
        #expect(result.total == 40)
        #expect(result.eCore == 0 && result.sCore == 100 && result.pCore == nil)
        #expect(result.cores == Array(repeating: 0, count: 6) + Array(repeating: 100, count: 4))
    }

    @Test("A three-tier M6 layout meters efficiency, super, and performance cores independently")
    func threeTierTopology() throws {
        let tags = [0: "M", 1: "P", 2: "E", 3: "M", 4: "E", 5: "E", 6: "M", 7: "E", 8: "E", 9: "P", 10: "M", 11: "E"]
        let topology = CPUTopology(logicalCPUCount: 12,
            performanceLevels: [("Super", 2), ("Performance", 4), ("Efficiency", 6)], firmwareTypes: tags)
        #expect(topology.clusters.map(\.role) == [.s, .p, .e])
        #expect(topology.clusters.map(\.count) == [2, 4, 6])
        #expect(topology.cores.map(\.machIndex) == [2, 4, 5, 7, 8, 11, 1, 9, 0, 3, 6, 10])
        #expect(topology.cores.map(\.label) == ["E0", "E1", "E2", "E3", "E4", "E5", "S0", "S1", "P0", "P1", "P2", "P3"])

        let noLevelNames = CPUTopology(logicalCPUCount: 12,
            performanceLevels: [(nil, 2), (nil, 4), (nil, 6)], firmwareTypes: tags)
        #expect(noLevelNames == topology)
        let wrongCounts = CPUTopology(logicalCPUCount: 12,
            performanceLevels: [(nil, 4), (nil, 4), (nil, 4)], firmwareTypes: tags)
        #expect(wrongCounts.clusters.isEmpty)

        var sampler = CPUUsageAccumulator(topology: topology)
        _ = read(Array(repeating: 0, count: 48), cpuCount: 12, into: &sampler, at: 1)
        let delta: [UInt32] = (0..<12).flatMap { cpu -> [UInt32] in
            let active: UInt32 = tags[cpu] == "E" ? 20 : tags[cpu] == "P" ? 100 : 40
            return [active, 0, 100 - active, 0]
        }
        let result = try #require(read(delta, cpuCount: 12, into: &sampler, at: 2))
        #expect(result.eCore == 20 && result.sCore == 100 && result.pCore == 40)
        #expect(result.total == 40)
    }

    @Test("32-core systems get accurate total CPU even without topology metadata")
    func aggregateWithNoTopology() throws {
        let topology = CPUTopology(logicalCPUCount: 32, performanceLevels: [("Efficiency", 8), ("Performance", 24)],
                                   firmwareTypes: [0: "E"])
        #expect(topology.logicalCPUCount == 32)
        #expect(topology.clusters.isEmpty)
        var sampler = CPUUsageAccumulator(topology: topology)
        _ = read(Array(repeating: 0, count: 128), cpuCount: 32, into: &sampler, at: 1)
        let delta: [UInt32] = (0..<32).flatMap { $0 < 24 ? [0, 0, 100, 0] : [100, 0, 0, 0] }
        let result = try #require(read(delta, cpuCount: 32, into: &sampler, at: 2))
        #expect(result.total == 25)
        #expect(result.cores.isEmpty)
        #expect(result.eCore == nil && result.sCore == nil && result.pCore == nil)
    }

    @Test("Changes in Mach CPU count establish an independent baseline")
    func vectorSizeChanges() throws {
        var sampler = CPUUsageAccumulator(topology: .fixture)
        _ = read(Array(repeating: 0, count: 72), into: &sampler, at: 1)
        let fewer: [UInt32] = [100, 0, 0, 0, 0, 0, 100, 0]
        #expect(read(fewer, cpuCount: 2, into: &sampler, at: 2) == nil)
        let result = try #require(read(fewer.map { $0 * 2 }, cpuCount: 2, into: &sampler, at: 3))
        #expect(result.total == 50)
        #expect(result.cores.isEmpty)
        #expect(result.eCore == nil && result.sCore == nil && result.pCore == nil)
    }
}
