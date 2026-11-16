// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum SeriesKey: Hashable, Sendable {
    case cpuTotal, cpuE, cpuS, cpuP, cpuPower, cpuTemperature, cpuFrequencyE, cpuFrequencyS, cpuFrequencyP
    case gpuUsage, gpuTemperature, gpuPower, anePower, gpuFrequency
    case memoryUsed, memoryPressure
    case powerInput, powerSystem, powerBattery, batteryState


    case coreUsageIndex(Int), coreTemperatureIndex(Int)

    public static let aggregateKeys: [Self] = [
        .cpuTotal, .cpuE, .cpuS, .cpuP, .cpuPower, .cpuTemperature, .cpuFrequencyE, .cpuFrequencyS, .cpuFrequencyP,
        .gpuUsage, .gpuTemperature, .gpuPower, .anePower, .gpuFrequency, .memoryUsed, .memoryPressure,
        .powerInput, .powerSystem, .powerBattery, .batteryState,
    ]

    public var rawValue: String {
        switch self {
        case .coreUsageIndex(let index): "cpuCoreUsage\(index)"
        case .coreTemperatureIndex(let index): "cpuCoreTemperature\(index)"
        case .cpuTotal: "cpuTotal"
        case .cpuE: "cpuE"
        case .cpuS: "cpuS"
        case .cpuP: "cpuP"
        case .cpuPower: "cpuPower"
        case .cpuTemperature: "cpuTemperature"
        case .cpuFrequencyE: "cpuFrequencyE"
        case .cpuFrequencyS: "cpuFrequencyS"
        case .cpuFrequencyP: "cpuFrequencyP"
        case .gpuUsage: "gpuUsage"
        case .gpuTemperature: "gpuTemperature"
        case .gpuPower: "gpuPower"
        case .anePower: "anePower"
        case .gpuFrequency: "gpuFrequency"
        case .memoryUsed: "memoryUsed"
        case .memoryPressure: "memoryPressure"
        case .powerInput: "powerInput"
        case .powerSystem: "powerSystem"
        case .powerBattery: "powerBattery"
        case .batteryState: "batteryState"
        }
    }

    public static func coreUsage(_ core: CoreID) -> Self {
        .coreUsageIndex(core.flatIndex)
    }

    public static func coreTemperature(_ core: CoreID) -> Self {
        .coreTemperatureIndex(core.flatIndex)
    }

    public var isPerCore: Bool {
        switch self {
        case .coreUsageIndex, .coreTemperatureIndex: true
        default: false
        }
    }

    /// Discrete levels are drawn as steps, never interpolated.
    public var isLevel: Bool {
        self == .memoryPressure || self == .batteryState
    }

    public var source: SourceID {
        switch self {
        case .cpuTotal, .cpuE, .cpuS, .cpuP, .coreUsageIndex: .cpuActivity
        case .coreTemperatureIndex: .sensors
        case .cpuFrequencyE, .cpuFrequencyS, .cpuFrequencyP: .cpuFrequency
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

    public var recordedKeys: [SeriesKey] { Array(series.keys) }

    public func append(_ key: SeriesKey, time: TimeInterval, value: Double, expectedInterval: TimeInterval) {
        series[key, default: TimeSeries()].append(time: time, value: value, expectedInterval: expectedInterval)
    }

    public func markBreak(_ key: SeriesKey) {
        series[key]?.markBreak()
    }

    public func markBreak(source: SourceID) {
        for key in series.keys where key.source == source {
            markBreak(key)
        }
    }

    public func markBreakAll() {
        for key in series.keys {
            markBreak(key)
        }
    }

    public func markBreakPerCore() {
        for key in series.keys where key.isPerCore { markBreak(key) }
    }

    public func removePerCore() {
        for key in series.keys where key.isPerCore { remove(key) }
    }

    public func clear(_ key: SeriesKey) {
        series[key]?.removeAll()
    }

    /// Drop storage as well as samples when a series has no visible consumer.
    public func remove(_ key: SeriesKey) {
        series.removeValue(forKey: key)
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
