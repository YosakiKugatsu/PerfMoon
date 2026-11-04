import Foundation

public enum SeriesKey: String, Hashable, Sendable, CaseIterable {
    case cpuTotal, cpuS, cpuP, cpuPower, cpuTemperature, cpuFrequencyS, cpuFrequencyP
    case gpuUsage, gpuTemperature, gpuPower, anePower, gpuFrequency
    case memoryUsed, memoryPressure
    case powerInput, powerSystem, powerBattery, batteryState

    /// Discrete levels are drawn as steps, never interpolated.
    public var isLevel: Bool {
        self == .memoryPressure || self == .batteryState
    }

    public var source: SourceID {
        switch self {
        case .cpuTotal, .cpuS, .cpuP: .cpuActivity
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
