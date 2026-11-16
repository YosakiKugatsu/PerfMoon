// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Reuse one baseline counter vector, sized from Mach rather than the chip name.
/// Cluster values are produced only when the topology agrees with that vector.
struct CPUUsageAccumulator {
    struct Value {
        let cores: [Double]
        let eCore: Double?
        let sCore: Double?
        let pCore: Double?
        let total: Double
        let window: TimeInterval
    }

    private let displayOrder: [CoreID]
    private let eCount: Int
    private let sCount: Int
    private let pCount: Int
    private var previous: [UInt32] = []
    private var previousTime: TimeInterval?

    init(topology: CPUTopology) {
        displayOrder = topology.cores.sorted { $0.machIndex < $1.machIndex }
        eCount = topology.cluster(.e)?.count ?? 0
        sCount = topology.cluster(.s)?.count ?? 0
        pCount = topology.cluster(.p)?.count ?? 0
    }

    mutating func reset() { previousTime = nil }

    mutating func sample(_ ticks: UnsafeBufferPointer<Int32>, cpuCount: Int, at time: TimeInterval) -> Value? {
        guard cpuCount > 0, cpuCount <= ticks.count / 4, ticks.count == cpuCount * 4 else {
            reset()
            return nil
        }
        if previous.count != ticks.count {
            previous = [UInt32](repeating: 0, count: ticks.count)
            reset()
        }
        let elapsed = previousTime.map { time - $0 } ?? 0
        let hasBaseline = previousTime != nil && elapsed > 0
        previousTime = time
        let hasMapping = displayOrder.count == cpuCount
        var cores = hasBaseline && hasMapping ? [Double](repeating: 0, count: cpuCount) : []
        var eSum = 0.0, sSum = 0.0, pSum = 0.0, totalSum = 0.0
        for cpu in 0..<cpuCount {
            var total: UInt64 = 0, idle: UInt64 = 0
            for state in 0..<4 {
                let index = cpu * 4 + state
                let current = UInt32(bitPattern: ticks[index])
                let delta = UInt64(current &- previous[index])
                previous[index] = current
                total += delta
                // CPU_STATE_IDLE is 2 in Mach's PROCESSOR_CPU_LOAD_INFO layout.
                if state == 2 { idle = delta }
            }
            guard hasBaseline else { continue }
            let percent = total > 0 ? 100 * Double(total - idle) / Double(total) : 0
            totalSum += percent
            if hasMapping {
                let id = displayOrder[cpu]
                cores[id.flatIndex] = percent
                switch id.cluster {
                case .e: eSum += percent
                case .s: sSum += percent
                case .p: pSum += percent
                }
            }
        }
        guard hasBaseline else { return nil }
        return Value(cores: cores,
                     eCore: hasMapping && eCount > 0 ? eSum / Double(eCount) : nil,
                     sCore: hasMapping && sCount > 0 ? sSum / Double(sCount) : nil,
                     pCore: hasMapping && pCount > 0 ? pSum / Double(pCount) : nil,
                     total: totalSum / Double(cpuCount), window: elapsed)
    }
}
