import Foundation

public enum SeriesKey: String, Hashable, Sendable, CaseIterable {
    case cpuTotal, cpuS, cpuP, cpuPower, cpuTemperature, cpuFrequencyS, cpuFrequencyP
    case gpuUsage, gpuTemperature, gpuPower, anePower, gpuFrequency
    case memoryUsed, memoryPressure
    case powerInput, powerSystem, powerBattery, batteryState


    // Fixed UI order: S0–S5, then P0–P11. These reuse existing hardware samples.
    case cpuCoreUsage0, cpuCoreUsage1, cpuCoreUsage2, cpuCoreUsage3, cpuCoreUsage4, cpuCoreUsage5
    case cpuCoreUsage6, cpuCoreUsage7, cpuCoreUsage8, cpuCoreUsage9, cpuCoreUsage10, cpuCoreUsage11
    case cpuCoreUsage12, cpuCoreUsage13, cpuCoreUsage14, cpuCoreUsage15, cpuCoreUsage16, cpuCoreUsage17
    case cpuCoreTemperature0, cpuCoreTemperature1, cpuCoreTemperature2, cpuCoreTemperature3, cpuCoreTemperature4, cpuCoreTemperature5
    case cpuCoreTemperature6, cpuCoreTemperature7, cpuCoreTemperature8, cpuCoreTemperature9, cpuCoreTemperature10, cpuCoreTemperature11
    case cpuCoreTemperature12, cpuCoreTemperature13, cpuCoreTemperature14, cpuCoreTemperature15, cpuCoreTemperature16, cpuCoreTemperature17

    private static let coreUsageKeys: [Self] = [
        .cpuCoreUsage0, .cpuCoreUsage1, .cpuCoreUsage2, .cpuCoreUsage3, .cpuCoreUsage4, .cpuCoreUsage5,
        .cpuCoreUsage6, .cpuCoreUsage7, .cpuCoreUsage8, .cpuCoreUsage9, .cpuCoreUsage10, .cpuCoreUsage11,
        .cpuCoreUsage12, .cpuCoreUsage13, .cpuCoreUsage14, .cpuCoreUsage15, .cpuCoreUsage16, .cpuCoreUsage17,
    ]
    private static let coreTemperatureKeys: [Self] = [
        .cpuCoreTemperature0, .cpuCoreTemperature1, .cpuCoreTemperature2, .cpuCoreTemperature3, .cpuCoreTemperature4, .cpuCoreTemperature5,
        .cpuCoreTemperature6, .cpuCoreTemperature7, .cpuCoreTemperature8, .cpuCoreTemperature9, .cpuCoreTemperature10, .cpuCoreTemperature11,
        .cpuCoreTemperature12, .cpuCoreTemperature13, .cpuCoreTemperature14, .cpuCoreTemperature15, .cpuCoreTemperature16, .cpuCoreTemperature17,
    ]

    public static func coreUsage(_ core: CoreID) -> Self {
        coreUsageKeys[core.flatIndex]
    }

    public static func coreTemperature(_ core: CoreID) -> Self {
        coreTemperatureKeys[core.flatIndex]
    }

    /// Discrete levels are drawn as steps, never interpolated.
    public var isLevel: Bool {
        self == .memoryPressure || self == .batteryState
    }

    public var source: SourceID {
        switch self {
        case .cpuTotal, .cpuS, .cpuP: .cpuActivity
        case .cpuCoreUsage0, .cpuCoreUsage1, .cpuCoreUsage2, .cpuCoreUsage3, .cpuCoreUsage4, .cpuCoreUsage5,
             .cpuCoreUsage6, .cpuCoreUsage7, .cpuCoreUsage8, .cpuCoreUsage9, .cpuCoreUsage10, .cpuCoreUsage11,
             .cpuCoreUsage12, .cpuCoreUsage13, .cpuCoreUsage14, .cpuCoreUsage15, .cpuCoreUsage16, .cpuCoreUsage17: .cpuActivity
        case .cpuCoreTemperature0, .cpuCoreTemperature1, .cpuCoreTemperature2, .cpuCoreTemperature3, .cpuCoreTemperature4, .cpuCoreTemperature5,
             .cpuCoreTemperature6, .cpuCoreTemperature7, .cpuCoreTemperature8, .cpuCoreTemperature9, .cpuCoreTemperature10, .cpuCoreTemperature11,
             .cpuCoreTemperature12, .cpuCoreTemperature13, .cpuCoreTemperature14, .cpuCoreTemperature15, .cpuCoreTemperature16, .cpuCoreTemperature17: .sensors
        case .cpuFrequencyS, .cpuFrequencyP: .cpuFrequency
        case .cpuPower, .gpuPower, .anePower: .energy
        case .cpuTemperature, .gpuTemperature, .powerInput, .powerSystem, .powerBattery: .sensors
        case .gpuUsage, .gpuFrequency: .gpuActivity
        case .memoryUsed: .memory
        case .memoryPressure: .memoryPressure
        case .batteryState: .battery
        }
    }
}

/// In-memory history for the last 15 minutes. Nothing is written to disk.
@MainActor
public final class HistoryStore {
    private var series: [SeriesKey: TimeSeries] = [:]

    public init() {}

    public func append(_ key: SeriesKey, time: TimeInterval, value: Double, expectedInterval: TimeInterval) {
        series[key, default: TimeSeries()].append(time: time, value: value, expectedInterval: expectedInterval)
    }

    public func markBreak(_ key: SeriesKey) {
        series[key, default: TimeSeries()].markBreak()
    }

    public func markBreak(source: SourceID) {
        for key in SeriesKey.allCases where key.source == source {
            markBreak(key)
        }
    }

    public func markBreakAll() {
        for key in SeriesKey.allCases {
            markBreak(key)
        }
    }

    public func clear(_ key: SeriesKey) {
        series[key]?.removeAll()
    }

    public func removeAll() {
        series.removeAll()
    }

    public func samples(_ key: SeriesKey, since time: TimeInterval) -> [HistorySample] {
        series[key]?.samples(since: time) ?? []
    }

    public func last(_ key: SeriesKey) -> HistorySample? {
        series[key]?.last
    }

    public func count(_ key: SeriesKey) -> Int {
        series[key]?.count ?? 0
    }

    public func series(_ key: SeriesKey) -> TimeSeries? {
        series[key]
    }

    /// Chart-ready points for a time window, bounded to roughly 180 vertices per series.
    public func points(_ key: SeriesKey, start: TimeInterval, end: TimeInterval, buckets: Int = Downsampler.defaultBuckets) -> [ChartPoint] {
        Downsampler.points(from: samples(key, since: start), start: start, end: end, buckets: buckets)
    }

    public func runs(_ key: SeriesKey, start: TimeInterval, end: TimeInterval) -> [LevelRun] {
        Downsampler.levelRuns(from: samples(key, since: start), end: end)
    }
}
