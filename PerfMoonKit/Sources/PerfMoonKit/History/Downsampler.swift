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
        let visible = samples.filter { $0.time >= start && $0.time <= end }
        guard !visible.isEmpty else { return [] }

        var segment = 0
        var segmentIndices: [Int] = []
        segmentIndices.reserveCapacity(visible.count)
        for (index, sample) in visible.enumerated() {
            if index > 0, sample.startsSegment { segment += 1 }
            segmentIndices.append(segment)
        }

        if visible.count <= buckets * 2 || end <= start {
            return visible.enumerated().map { index, sample in
                ChartPoint(time: sample.time, value: Double(sample.value), segment: segmentIndices[index])
            }
        }

        let width = (end - start) / Double(buckets)
        var result: [ChartPoint] = []
        result.reserveCapacity(buckets * 2 + segment * 2 + 2)

        var groupBucket = -1
        var groupSegment = -1
        var minIndex = 0
        var maxIndex = 0

        func flush() {
            guard groupBucket >= 0 else { return }
            let first = min(minIndex, maxIndex)
            let second = max(minIndex, maxIndex)
            let a = visible[first]
            result.append(ChartPoint(time: a.time, value: Double(a.value), segment: groupSegment))
            if second != first {
                let b = visible[second]
                result.append(ChartPoint(time: b.time, value: Double(b.value), segment: groupSegment))
            }
        }

        for (index, sample) in visible.enumerated() {
            let bucket = min(buckets - 1, max(0, Int((sample.time - start) / width)))
            let sampleSegment = segmentIndices[index]
            if bucket != groupBucket || sampleSegment != groupSegment {
                flush()
                groupBucket = bucket
                groupSegment = sampleSegment
                minIndex = index
                maxIndex = index
            } else {
                if sample.value < visible[minIndex].value { minIndex = index }
                if sample.value > visible[maxIndex].value { maxIndex = index }
            }
        }
        flush()
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
