import Testing
@testable import PerfMoonKit

@MainActor
@Suite("Physical memory composition")
struct MemoryCompositionTests {
    private func memory() -> MemorySnapshot {
        let core = MonitorCore(provider: FixtureProvider(scenario: .typical, anchor: 1000))
        core.start(now: 1000)
        core.tick(now: 1000)
        return core.snapshot(now: 1000).memory
    }

    private func bytes(_ value: Double) -> MetricReading {
        MetricReading(value: value, unit: .bytes, status: .valid, source: .memory)
    }

    @Test("Reusable subdivides App and leaves Used and Available unchanged")
    func reusableDoesNotDoubleCount() throws {
        var m = memory()
        m.physical = 64
        m.app = bytes(30); m.wired = bytes(8); m.compressed = bytes(2)
        m.used = bytes(40); m.reusable = bytes(11)
        // These overlapping diagnostics must not be added to the partition.
        m.cached = bytes(21); m.free = bytes(4); m.purgeable = bytes(3)
        let c = try #require(m.composition)
        #expect(c.app == 19)
        #expect(c.reusable == 11)
        #expect(c.available == 24)
        #expect(c.app + (c.reusable ?? 0) + c.wired + c.compressed + c.available == 64)
        #expect(m.used.value == 40)
        #expect(m.app.value == 30)
    }

    @Test("Adjacent VM counter reads cannot overflow the bar or produce negative segments")
    func racesRemainBounded() throws {
        var m = memory()
        m.physical = 64
        m.app = bytes(50); m.wired = bytes(14); m.compressed = bytes(6)
        m.used = bytes(64); m.reusable = bytes(80)
        let c = try #require(m.composition)
        #expect(c.app == 0)
        #expect(c.available == 0)
        #expect(abs(c.app + (c.reusable ?? 0) + c.wired + c.compressed - 64) < 0.000001)
        #expect([c.app, c.reusable ?? 0, c.wired, c.compressed].allSatisfy { $0 >= 0 })
    }

    @Test("Unsupported Reusable remains unknown; absent main components request fallback")
    func unavailableReadings() throws {
        var m = memory()
        m.reusable = MetricReading(value: nil, unit: .bytes, status: .unavailable(.unsupported))
        let c = try #require(m.composition)
        #expect(c.reusable == nil)
        #expect(abs(c.app + c.wired + c.compressed + c.available - c.physical) < 0.1)
        m.app = .pending(.bytes)
        #expect(m.composition == nil)
    }
}
