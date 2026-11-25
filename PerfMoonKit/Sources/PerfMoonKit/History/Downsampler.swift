// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct ChartPoint: Sendable, Equatable {
    public var time: TimeInterval
    public var value: Double
    /// Index of the continuous segment; points in different segments must not be joined.
    public var segment: Int

    public init(time: TimeInterval, value: Double, segment: Int) {
        self.time = time
        self.value = value
        self.segment = segment
    }

    public var date: Date { Date(timeIntervalSinceReferenceDate: time) }
}

/// A run of one discrete level within one continuous segment.
public struct LevelRun: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var level: Int
    public var segment: Int

    public init(start: TimeInterval, end: TimeInterval, level: Int, segment: Int) {
        self.start = start
        self.end = end
        self.level = level
        self.segment = segment
    }
}

public enum Downsampler {
    /// 90 buckets × (min, max) ≈ 180 vertices.
    public static let defaultBuckets = 90

    /// Splits the window into buckets and keeps each bucket's minimum and maximum in time order.
    /// Buckets never span a segment break, so gaps stay gaps.
    public static func points(from samples: [HistorySample], start: TimeInterval, end: TimeInterval, buckets: Int = defaultBuckets) -> [ChartPoint] {
        var visible = samples[...]
        while let sample = visible.first, sample.time < start { visible.removeFirst() }
        while let sample = visible.last, sample.time > end { visible.removeLast() }
        guard let first = visible.first, buckets > 0 else { return [] }
        var segment = 0
        if visible.count <= buckets * 2 || end <= start {
            return visible.enumerated().map { index, sample in
                if index > 0 && sample.startsSegment { segment += 1 }
                return ChartPoint(time: sample.time, value: Double(sample.value), segment: segment)
            }
        }

        let width = (end - start) / Double(buckets)
        var result: [ChartPoint] = []
        result.reserveCapacity(buckets * 2 + 2)
        func add(_ sample: HistorySample) {
            if result.last?.time != sample.time {
                result.append(ChartPoint(time: sample.time, value: Double(sample.value), segment: segment))
            }
        }
        var low = first, high = first, last = first
        var bucket = min(buckets - 1, Int((first.time - start) / width))
        func flush() {
            if low.time <= high.time { add(low); add(high) }
            else { add(high); add(low) }
        }
        add(first)
        for sample in visible.dropFirst() {
            let next = min(buckets - 1, Int((sample.time - start) / width))
            if sample.startsSegment || next != bucket {
                flush()
                if sample.startsSegment {
                    add(last)
                    segment += 1
                    add(sample)
                }
                low = sample
                high = sample
                bucket = next
            } else {
                if sample.value < low.value { low = sample }
                if sample.value > high.value { high = sample }
            }
            last = sample
        }
        flush()
        add(last)
        return result
    }

    /// Converts level samples into runs. A run ends at the next sample in its segment;
    /// the last run of a segment covers one typical sample spacing.
    public static func levelRuns(from samples: [HistorySample], end: TimeInterval) -> [LevelRun] {
        guard !samples.isEmpty else { return [] }
        var runs: [LevelRun] = []
        var segment = 0
        var index = 0
        while index < samples.count {
            // Collect one segment.
            var segmentEnd = index + 1
            while segmentEnd < samples.count, !samples[segmentEnd].startsSegment { segmentEnd += 1 }
            let slice = samples[index..<segmentEnd]
            let spacing: TimeInterval = slice.count > 1
                ? (slice.last!.time - slice.first!.time) / Double(slice.count - 1)
                : 1
            var runStart = slice.first!.time
            var runLevel = Int(slice.first!.value.rounded())
            var previousTime = runStart
            for sample in slice.dropFirst() {
                let level = Int(sample.value.rounded())
                if level != runLevel {
                    runs.append(LevelRun(start: runStart, end: sample.time, level: runLevel, segment: segment))
                    runStart = sample.time
                    runLevel = level
                }
                previousTime = sample.time
            }
            runs.append(LevelRun(start: runStart, end: min(end, previousTime + spacing), level: runLevel, segment: segment))
            segment += 1
            index = segmentEnd
        }
        return runs
    }
}
