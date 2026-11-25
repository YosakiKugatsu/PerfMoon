// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct HistorySample: Sendable, Equatable {
    /// Seconds since the reference date.
    public var time: TimeInterval
    public var value: Float
    /// True when this sample must not be connected to the previous one.
    public var startsSegment: Bool

    public init(time: TimeInterval, value: Float, startsSegment: Bool) {
        self.time = time
        self.value = value
        self.startsSegment = startsSegment
    }
}

/// A bounded, timestamped ring buffer that records discontinuities instead of bridging them.
public struct TimeSeries: Sendable {
    public static let defaultRetention: TimeInterval = 15 * 60
    /// A new segment starts when samples are further apart than this many expected intervals.
    public static let gapFactor: Double = 2.5

    public let capacity: Int
    public let retention: TimeInterval
    private let initialCapacity: Int
    private var storage: ContiguousArray<HistorySample> = []
    private var start = 0
    private var lastInterval: TimeInterval = 0
    public private(set) var count = 0
    /// Set by explicit events (pause, sleep, source change, failure); the next sample starts a segment.
    public private(set) var pendingBreak = true

    public init(retention: TimeInterval = TimeSeries.defaultRetention, capacity: Int = 1024) {
        self.init(retention: retention, capacity: capacity, initialCapacity: capacity)
    }

    init(retention: TimeInterval, capacity: Int, initialCapacity: Int) {
        self.retention = retention
        self.capacity = max(1, capacity)
        self.initialCapacity = max(1, min(capacity, initialCapacity))
    }

    public var isEmpty: Bool { count == 0 }
    var bufferBytes: Int { storage.capacity * MemoryLayout<HistorySample>.stride }

    public var last: HistorySample? {
        count == 0 ? nil : self[count - 1]
    }

    public subscript(position: Int) -> HistorySample {
        var sample = stored(position)
        if position == 0 { sample.startsSegment = true }
        return sample
    }

    private func stored(_ position: Int) -> HistorySample {
        storage[slot(position)]
    }

    public mutating func markBreak() {
        pendingBreak = true
    }

    public mutating func removeAll() {
        storage = []
        lastInterval = 0
        start = 0
        count = 0
        pendingBreak = true
    }

    /// Appends a sample taken `expectedInterval` after the previous one was due.
    /// Samples that do not move forward in time are ignored.
    public mutating func append(time: TimeInterval, value: Double, expectedInterval: TimeInterval) {
        _ = append(time: time, value: value, expectedInterval: expectedInterval, evict: { _ in })
    }

    /// Evicted samples retain their *original* segment markers at the handoff
    /// from the full-resolution ring to the older, compact history.
    @discardableResult
    mutating func append(time: TimeInterval, value: Double, expectedInterval: TimeInterval,
                         evict: (HistorySample) -> Void) -> HistorySample? {
        guard value.isFinite else {
            pendingBreak = true
            return nil
        }
        var startsSegment = pendingBreak
        if let last {
            guard time > last.time else { return nil }
            if time - last.time > TimeSeries.gapFactor * max(expectedInterval, lastInterval) {
                startsSegment = true
            }
        } else {
            startsSegment = true
        }
        pendingBreak = false
        lastInterval = expectedInterval
        let sample = HistorySample(time: time, value: Float(value), startsSegment: startsSegment)
        if count == capacity { evict(storage[start]) }
        appendRecorded(sample)
        discard(before: time - retention, evict: evict)
        return sample
    }

    /// Samples at or after `time`, oldest first.
    public func samples(since time: TimeInterval) -> [HistorySample] {
        samples(since: time, preservingHead: false)
    }

    func samples(since time: TimeInterval, preservingHead: Bool) -> [HistorySample] {
        guard count > 0 else { return [] }
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].time < time { low = mid + 1 } else { high = mid }
        }
        var result: [HistorySample] = []
        result.reserveCapacity(count - low)
        for index in low..<count { result.append(stored(index)) }
        if !preservingHead, low == 0, !result.isEmpty { result[0].startsSegment = true }
        return result
    }

    public func allSamples() -> [HistorySample] {
        (0..<count).map { self[$0] }
    }

    /// The archive calls this with already-segmented envelope points. Grow on
    /// demand and reuse retired slots instead of retaining discarded prefixes.
    mutating func appendRecorded(_ sample: HistorySample) {
        if count == storage.count && count < capacity {
            let size = count == 0 ? initialCapacity : min(capacity, count * 2)
            var grown = ContiguousArray(repeating: sample, count: size)
            for i in 0..<count { grown[i] = stored(i) }
            storage = grown
            start = 0
        }
        if count < capacity {
            storage[slot(count)] = sample
            count += 1
        } else {
            storage[start] = sample
            start = slot(1)
        }
    }

    mutating func discard(before cutoff: TimeInterval, evict: (HistorySample) -> Void) {
        while count > 0 && storage[start].time < cutoff {
            evict(storage[start])
            start = slot(1)
            count -= 1
        }
    }

    private func slot(_ position: Int) -> Int {
        let index = start + position
        return index < storage.count ? index : index - storage.count
    }
}
