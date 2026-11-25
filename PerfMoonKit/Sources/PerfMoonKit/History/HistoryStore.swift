// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum MemoryStatistic: String, Hashable, Sendable {
    case available, app, wired, compressed, cached, purgeable, reusable, free, swapUsed, pageIns, pageOuts, swapIns, swapOuts
}

public enum CapacityStatistic: Hashable, Sendable {
    case used, available, allocated, reclaimable, volume(String)
}

public enum SeriesKey: Hashable, Sendable {
    case cpuTotal, cpuE, cpuS, cpuP, cpuPower, cpuTemperature, cpuFrequencyE, cpuFrequencyS, cpuFrequencyP
    case gpuUsage, gpuTemperature, gpuPower, anePower, gpuFrequency
    case memoryUsed, memoryPressure
    case memoryDetail(MemoryStatistic)
    case capacity(String, CapacityStatistic)
    case powerInput, powerSystem, powerBattery, batteryState


    case diskActivity(UInt64, DiskActivityMetric)
    case networkDownload, networkUpload
    case coreUsageIndex(Int), coreTemperatureIndex(Int), corePowerIndex(Int)

    public static let aggregateKeys: [Self] = [
        .cpuTotal, .cpuE, .cpuS, .cpuP, .cpuPower, .cpuTemperature, .cpuFrequencyE, .cpuFrequencyS, .cpuFrequencyP,
        .gpuUsage, .gpuTemperature, .gpuPower, .anePower, .gpuFrequency, .memoryUsed, .memoryPressure,
        .powerInput, .powerSystem, .powerBattery, .batteryState,
    ]

    public var rawValue: String {
        switch self {
        case .diskActivity(let mediaID, let metric): "disk\(mediaID)-\(metric.rawValue)"
        case .networkDownload: "networkDownload"
        case .networkUpload: "networkUpload"
        case .corePowerIndex(let index): "cpuCorePower\(index)"
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
        case .memoryDetail(let metric): "memory-\(metric.rawValue)"
        case .capacity(let drive, let metric): "capacity-\(drive)-\(metric)"
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

    public static func corePower(_ core: CoreID) -> Self { .corePowerIndex(core.flatIndex) }

    public static func coreTemperature(_ core: CoreID) -> Self {
        .coreTemperatureIndex(core.flatIndex)
    }

    public var isPerCore: Bool {
        switch self {
        case .coreUsageIndex, .coreTemperatureIndex, .corePowerIndex: true
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
        case .corePowerIndex: .corePower
        case .coreTemperatureIndex: .sensors
        case .cpuFrequencyE, .cpuFrequencyS, .cpuFrequencyP: .cpuFrequency
        case .cpuPower, .gpuPower, .anePower: .energy
        case .cpuTemperature, .gpuTemperature, .powerInput, .powerSystem, .powerBattery: .sensors
        case .gpuUsage, .gpuFrequency: .gpuActivity
        case .diskActivity: .diskActivity
        case .networkDownload, .networkUpload: .network
        case .capacity: .disk
        case .memoryDetail, .memoryUsed: .memory
        case .memoryPressure: .memoryPressure
        case .batteryState: .battery
        }
    }
}

/// Fifteen minutes of raw readings and six hours of chart history, all in memory.
@MainActor
public final class HistoryStore {
    private var series: [SeriesKey: RecordedSeries] = [:]
    private var transfers: [TransferHistoryKey: TransferHistory] = [:]

    public init() {}

    public var recordedKeys: [SeriesKey] { Array(series.keys) }

    public func statistics(for keys: [SeriesKey], from start: Double, through end: Double) async -> [SeriesKey: RangeStatistics] {
        guard start.isFinite, end.isFinite, end >= start else { return [:] }
        let range = max(start, end - TimeRange.sixHours.seconds)...end
        let snapshot = keys.compactMap { key in key.isLevel ? nil : series[key].map { (key, $0) } }
        let job = Task.detached(priority: .utility) {
            var result: [SeriesKey: RangeStatistics] = [:]
            for (key, data) in snapshot {
                if Task.isCancelled { break }
                result[key] = data.statistics(in: range)
            }
            return result
        }
        return await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    }

    public func append(_ key: SeriesKey, time: TimeInterval, value: Double, expectedInterval: TimeInterval) {
        series[key, default: RecordedSeries()].append(time: time, value: value, interval: expectedInterval, isLevel: key.isLevel)
    }

    public func markBreak(_ key: SeriesKey) {
        series[key]?.recent.markBreak()
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
        series[key] = nil
    }

    /// Drop storage as well as samples when a series has no visible consumer.
    public func remove(_ key: SeriesKey) {
        series.removeValue(forKey: key)
    }

    public func removeAll() {
        series.removeAll()
        transfers.removeAll()
    }

    func recordTransfer(_ rates: TransferRates, for key: TransferHistoryKey) {
        transfers[key, default: TransferHistory()].append(rates)
    }

    func removeTransfers(for key: TransferHistoryKey) { transfers.removeValue(forKey: key) }

    public func transferTotal(for key: TransferHistoryKey, from start: TimeInterval, to end: TimeInterval) -> TransferTotal? {
        transfers[key]?.total(from: start, to: end)
    }

    public func samples(_ key: SeriesKey, since time: TimeInterval) -> [HistorySample] {
        series[key]?.recent.samples(since: time) ?? []
    }

    public func last(_ key: SeriesKey) -> HistorySample? {
        series[key]?.recent.last
    }

    public func count(_ key: SeriesKey) -> Int {
        series[key]?.recent.count ?? 0
    }

    /// Allocated sample and level-run buffers for collector diagnostics.
    public func bufferBytes(_ key: SeriesKey) -> Int { series[key]?.bufferBytes ?? 0 }

    public func series(_ key: SeriesKey) -> TimeSeries? {
        series[key]?.recent
    }

    /// Chart-ready points for a time window, bounded to roughly 180 vertices per series.
    public func points(_ key: SeriesKey, start: TimeInterval, end: TimeInterval, buckets: Int = Downsampler.defaultBuckets) -> [ChartPoint] {
        guard let data = series[key] else { return [] }
        return Downsampler.points(from: data.chartSamples(start: start, end: end), start: start, end: end, buckets: buckets)
    }

    public func runs(_ key: SeriesKey, start: TimeInterval, end: TimeInterval) -> [LevelRun] {
        series[key]?.levels.visible(start: start, end: end) ?? []
    }
}
