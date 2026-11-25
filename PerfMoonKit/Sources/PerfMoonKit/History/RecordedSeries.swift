// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Old readings move into the archive only as they leave the short ring.
/// The normal 60-second panel reads and 1–15 minute charts use only that ring.
struct RecordedSeries: Sendable {
    var recent = TimeSeries()
    private var archive = EnvelopeArchive()
    private var statisticsArchive = StatisticsArchive()
    private(set) var levels = LevelTimeline()

    var bufferBytes: Int { recent.bufferBytes + archive.bufferBytes + levels.bufferBytes + statisticsArchive.bufferBytes }

    mutating func append(time: TimeInterval, value: Double, interval: TimeInterval, isLevel: Bool) {
        let cutoff = time - TimeRange.sixHours.seconds
        let sample = recent.append(time: time, value: value, expectedInterval: interval) { evicted in
            if !isLevel, evicted.time >= cutoff {
                archive.append(evicted)
                statisticsArchive.append(evicted)
            }
        }
        guard let sample else { return }
        if isLevel { levels.append(sample, interval: interval, cutoff: cutoff) }
        else {
            archive.expire(before: cutoff)
            statisticsArchive.expire(before: cutoff)
        }
    }

    func statistics(in requested: ClosedRange<Double>) -> RangeStatistics? {
        guard let newest = recent.last else { return nil }
        let lower = max(requested.lowerBound, newest.time - TimeRange.sixHours.seconds)
        guard lower <= requested.upperBound else { return nil }
        let range = lower...requested.upperBound
        var values: [Float] = []
        var first: Double?, last: Double?
        func add(_ t: Double, _ value: Float) {
            if first == nil { first = t }
            last = t
            values.append(value)
        }
        if !recent.isEmpty && range.lowerBound < recent[0].time {
            statisticsArchive.collect(in: range, into: add)
        }
        for sample in recent.samples(since: range.lowerBound) where sample.time <= range.upperBound {
            add(sample.time, sample.value)
        }
        return RangeStatistics(values: values, first: first, last: last)
    }

    func chartSamples(start: TimeInterval, end: TimeInterval) -> [HistorySample] {
        if recent.isEmpty || start >= recent[0].time { return recent.samples(since: start) }
        var result = archive.samples(since: max(start, end - TimeRange.sixHours.seconds))
        result += recent.samples(since: start, preservingHead: true)
        return result
    }
}

/// Keep the endpoints and extrema at their original timestamps. A source break
/// closes even a partially filled bucket, so no envelope bridges a real gap.
private struct EnvelopeArchive {
    private static let bucketWidth: TimeInterval = 30

    private struct Bucket {
        let end: TimeInterval
        let first: HistorySample
        var low: HistorySample
        var high: HistorySample
        var last: HistorySample

        init(_ sample: HistorySample) {
            end = (floor(sample.time / EnvelopeArchive.bucketWidth) + 1) * EnvelopeArchive.bucketWidth
            first = sample
            low = sample
            high = sample
            last = sample
        }

        mutating func add(_ sample: HistorySample) {
            if sample.value < low.value { low = sample }
            if sample.value > high.value { high = sample }
            last = sample
        }

        func emit(_ append: (HistorySample) -> Void) {
            append(first)
            let (a, b) = low.time <= high.time ? (low, high) : (high, low)
            if a.time > first.time && a.time < last.time { append(a) }
            if b.time > a.time && b.time < last.time { append(b) }
            if last.time > first.time { append(last) }
        }
    }

    // Allocate the ordinary six-hour envelope on first eviction. Grow only
    // if real segment breaks produce more than four points per bucket.
    private var saved = TimeSeries(retention: TimeRange.sixHours.seconds,
                                   capacity: Int(TimeRange.sixHours.seconds) * 2,
                                   initialCapacity: 4 * (Int((TimeRange.sixHours.seconds - TimeSeries.defaultRetention) / bucketWidth) + 2))
    var bufferBytes: Int { saved.bufferBytes }
    private var bucket: Bucket?

    mutating func append(_ sample: HistorySample) {
        if let current = bucket, !sample.startsSegment && sample.time < current.end {
            bucket?.add(sample)
        } else {
            bucket?.emit { saved.appendRecorded($0) }
            bucket = Bucket(sample)
        }
    }

    mutating func expire(before cutoff: TimeInterval) {
        saved.discard(before: cutoff, evict: { _ in })
        if let bucket, bucket.last.time < cutoff { self.bucket = nil }
    }

    func samples(since start: TimeInterval) -> [HistorySample] {
        var result = saved.samples(since: start, preservingHead: true)
        bucket?.emit { if $0.time >= start { result.append($0) } }
        return result
    }
}

/// Store the actual transitions for discrete readings, including short alarms.
/// A constant level costs one run however long it lasts.
struct LevelTimeline {
    private var runs: ArraySlice<LevelRun> = []
    var bufferBytes: Int { runs.capacity * MemoryLayout<LevelRun>.stride }

    mutating func append(_ sample: HistorySample, interval: TimeInterval, cutoff: TimeInterval) {
        let level = Int(sample.value.rounded())
        let end = sample.time + interval
        if let previous = runs.last {
            let last = runs.index(before: runs.endIndex)
            if previous.level == level && !sample.startsSegment {
                runs[last].end = end
            } else {
                runs[last].end = sample.startsSegment ? min(previous.end, sample.time) : sample.time
                runs.append(LevelRun(start: sample.time, end: end, level: level, segment: previous.segment + (sample.startsSegment ? 1 : 0)))
            }
        } else {
            runs.append(LevelRun(start: sample.time, end: end, level: level, segment: 0))
        }
        while let first = runs.first, first.end < cutoff { runs.removeFirst() }
        if runs.startIndex >= 256 && runs.startIndex >= runs.count { runs = ArraySlice(Array(runs)) }
        if let first = runs.first, first.start < cutoff { runs[runs.startIndex].start = cutoff }
    }

    func visible(start: TimeInterval, end: TimeInterval) -> [LevelRun] {
        var first = runs.startIndex, high = runs.endIndex
        while first < high {
            let mid = first + (high - first) / 2
            if runs[mid].end > start { high = mid } else { first = mid + 1 }
        }
        var result: [LevelRun] = []
        for var run in runs[first...] {
            if run.start >= end { break }
            run.start = max(start, run.start)
            run.end = min(end, run.end)
            result.append(run)
        }
        return result
    }
}
