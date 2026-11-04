import Foundation

/// Deterministic value noise. The same seed, channel, and time always give the same value,
/// so prefilled history and live samples describe one continuous story.
struct SmoothNoise: Sendable {
    let seed: UInt64

    @inline(__always)
    static func mix(_ input: UInt64) -> UInt64 {
        var z = input &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in -1...1 at an integer lattice point.
    func lattice(_ channel: UInt64, _ index: Int64) -> Double {
        let hash = Self.mix(seed ^ Self.mix(channel &* 0x0000_0100_0000_01B3 ^ UInt64(bitPattern: index)))
        return Double(hash >> 11) / Double(1 << 53) * 2 - 1
    }

    /// Smooth noise in -1...1 with features roughly `period` seconds apart.
    func smooth(_ channel: UInt64, _ time: Double, period: Double) -> Double {
        let x = time / period
        let floorX = x.rounded(.down)
        let fraction = x - floorX
        let eased = fraction * fraction * (3 - 2 * fraction)
        let index = Int64(floorX)
        let a = lattice(channel, index)
        let b = lattice(channel, index + 1)
        return a + (b - a) * eased
    }

    /// Three octaves of smooth noise, in -1...1.
    func fbm(_ channel: UInt64, _ time: Double, period: Double) -> Double {
        smooth(channel, time, period: period) * 0.6
            + smooth(channel &+ 7919, time, period: period / 3.1) * 0.28
            + smooth(channel &+ 15_485_863, time, period: period / 9.7) * 0.12
    }

    /// Occasional bursts in 0...1; zero most of the time.
    func burst(_ channel: UInt64, _ time: Double, period: Double, threshold: Double = 0.4) -> Double {
        let value = (smooth(channel, time, period: period) - threshold) / (1 - threshold)
        let clamped = min(1, max(0, value))
        return clamped * clamped.squareRoot()
    }
}

func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(upper, max(lower, value))
}
