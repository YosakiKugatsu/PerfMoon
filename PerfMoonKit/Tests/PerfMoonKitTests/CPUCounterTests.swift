import Testing
@testable import PerfMoonKit

@Suite("Mach CPU counter accounting")
struct CPUCounterTests {
    private func read(_ values: [UInt32], into sampler: inout CPUUsageAccumulator, at time: Double) -> CPUUsageAccumulator.Value? {
        values.map { Int32(bitPattern: $0) }.withUnsafeBufferPointer { sampler.sample($0, at: time) }
    }

    @Test("A single busy S-Core has correct physical order and weighted totals")
    func oneSuperCore() throws {
        var sampler = CPUUsageAccumulator()
        var values = [UInt32](repeating: 0, count: 72)
        #expect(read(values, into: &sampler, at: 100) == nil)
        for cpu in 0..<18 { values[cpu * 4 + 2] = 100 }
        values[12 * 4] = 100; values[12 * 4 + 2] = 0
        let result = try #require(read(values, into: &sampler, at: 102.25))
        #expect(result.cores[0] == 100)
        #expect(result.cores.dropFirst().allSatisfy { $0 == 0 })
        #expect(abs(result.sCore - 100.0 / 6) < 1e-9)
        #expect(result.pCore == 0)
        #expect(abs(result.total - 100.0 / 18) < 1e-9)
        #expect(result.window == 2.25)
    }

    @Test("Both ends of the two core groups map to their own UI indices")
    func groupMapping() throws {
        var sampler = CPUUsageAccumulator()
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
        var sampler = CPUUsageAccumulator()
        var values = [UInt32](repeating: 0, count: 72)
        for cpu in 0..<18 { values[cpu * 4] = .max - 4; values[cpu * 4 + 2] = .max - 4 }
        _ = read(values, into: &sampler, at: 1)
        for cpu in 0..<18 { values[cpu * 4] = 3; values[cpu * 4 + 2] = 11 }
        let result = try #require(read(values, into: &sampler, at: 2))
        #expect(result.cores.allSatisfy { abs($0 - 100.0 / 3) < 1e-9 })
    }

    @Test("Reset, non-advancing time, and malformed input never reuse stale deltas")
    func resets() throws {
        var sampler = CPUUsageAccumulator()
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
}
