import Foundation

/// Fixed storage for Mach's 18 × 4 counters. A sample allocates only its output
/// vector, rather than a nested array and another delta array for every core.
struct CPUUsageAccumulator {
    struct Value {
        let cores: [Double]
        let sCore: Double
        let pCore: Double
        let total: Double
        let window: TimeInterval
    }

    private var previous = [UInt32](repeating: 0, count: 72)
    private var previousTime: TimeInterval?

    mutating func reset() { previousTime = nil }

    mutating func sample(_ ticks: UnsafeBufferPointer<Int32>, at time: TimeInterval) -> Value? {
        guard ticks.count >= 72 else { reset(); return nil }
        let elapsed = previousTime.map { time - $0 } ?? 0
        let hasBaseline = previousTime != nil && elapsed > 0
        previousTime = time
        var cores = hasBaseline ? [Double](repeating: 0, count: 18) : []
        var sSum = 0.0, pSum = 0.0
        for cpu in 0..<18 {
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
            // Verified against powermetrics: CPUs 12–17 are S; CPUs 0–11 are P.
            if cpu >= 12 { cores[cpu - 12] = percent; sSum += percent }
            else { cores[cpu + 6] = percent; pSum += percent }
        }
        guard hasBaseline else { return nil }
        return Value(cores: cores, sCore: sSum / 6, pCore: pSum / 12,
                     total: (sSum + pSum) / 18, window: elapsed)
    }
}
