// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Testing
@testable import PerfMoonKit

@Suite("Selected range statistics")
@MainActor
struct RangeStatisticsTests {
    @Test("Archived and recent samples retain their distribution, timestamps, gaps and zeros")
    func allWindows() async throws {
        let history = HistoryStore()
        let end = 25_000.0
        var reference: [(Double, Double)] = []
        for tick in 0...25_000 where !(953...1300).contains(tick) {
            let time = Double(tick) + Double(tick % 3) / 10
            let value = tick % 29 == 0 ? 999.0 : Double(tick % 9)
            history.append(.cpuPower, time: time, value: value, expectedInterval: 1)
            reference.append((time, value))
        }
        for range in TimeRange.allCases {
            let start = end - range.seconds
            let expected = reference.filter { $0.0 >= start && $0.0 <= end }
            let result = await history.statistics(for: [.cpuPower, .gpuPower], from: start, through: end)
            let stats = try #require(result[.cpuPower])
            let values = expected.map { $0.1 }.sorted()
            #expect(stats.count == values.count)
            #expect(stats.firstTime == expected.first?.0 && stats.lastTime == expected.last?.0)
            #expect(stats.average == values.reduce(0,+) / Double(values.count))
            #expect(stats.minimum == values.first && stats.maximum == values.last)
            #expect(stats.p95 == values[Int((Double(values.count) * 0.95).rounded(.up)) - 1])
            #expect(result[.gpuPower] == nil)
        }
        history.clear(.cpuPower)
        let cleared = await history.statistics(for: [.cpuPower], from: 0, through: end)
        #expect(cleared.isEmpty)
    }

    @Test("A missing interval contributes no zeros; one real zero remains a sample")
    func gaps() async {
        let h = HistoryStore()
        h.append(.networkUpload, time: 10, value: 500, expectedInterval: 1)
        h.markBreak(.networkUpload)
        h.append(.networkUpload, time: 50, value: 0, expectedInterval: 1)
        let gap = await h.statistics(for: [.networkUpload], from: 11, through: 49)
        #expect(gap.isEmpty)
        let single = await h.statistics(for: [.networkUpload], from: 49, through: 50)
        #expect(single[.networkUpload]?.count == 1 && single[.networkUpload]?.p95 == 0)
    }
}
