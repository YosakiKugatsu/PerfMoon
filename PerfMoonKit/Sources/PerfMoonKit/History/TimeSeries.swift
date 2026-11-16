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
    private var storage: ContiguousArray<HistorySample> = []
    private var start = 0
    public private(set) var count = 0
    /// Set by explicit events (pause, sleep, source change, failure); the next sample starts a segment.
    public private(set) var pendingBreak = true

    public init(retention: TimeInterval = TimeSeries.defaultRetention, capacity: Int = 1024) {
        self.retention = retention
        self.capacity = capacity
    }

    public var isEmpty: Bool { count == 0 }

    public var last: HistorySample? {
        count == 0 ? nil : self[count - 1]
    }

    public subscript(position: Int) -> HistorySample {
        storage[(start + position) % capacity]
    }

    public mutating func markBreak() {
        pendingBreak = true
    }

    public mutating func removeAll() {
        storage = []
        start = 0
        count = 0
        pendingBreak = true
    }

    /// Appends a sample taken `expectedInterval` after the previous one was due.
    /// Samples that do not move forward in time are ignored.
    public mutating func append(time: TimeInterval, value: Double, expectedInterval: TimeInterval) {
        guard value.isFinite else {
            pendingBreak = true
            return
        }
        var startsSegment = pendingBreak
        if let last {
            guard time > last.time else { return }
            if time - last.time > TimeSeries.gapFactor * expectedInterval {
                startsSegment = true
            }
        } else {
            startsSegment = true
        }
        pendingBreak = false
        push(HistorySample(time: time, value: Float(value), startsSegment: startsSegment))
        trim(before: time - retention)
    }

    /// Samples at or after `time`, oldest first.
    public func samples(since time: TimeInterval) -> [HistorySample] {
        guard count > 0 else { return [] }
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid].time < time { low = mid + 1 } else { high = mid }
        }
        var result: [HistorySample] = []
        result.reserveCapacity(count - low)
        for index in low..<count { result.append(self[index]) }
        return result
    }

    public func allSamples() -> [HistorySample] {
        (0..<count).map { self[$0] }
    }

    private mutating func push(_ sample: HistorySample) {
        if storage.isEmpty {
            storage = ContiguousArray(repeating: sample, count: capacity)
            start = 0
            count = 1
            return
        }
        if count < capacity {
            storage[(start + count) % capacity] = sample
            count += 1
        } else {
            storage[start] = sample
            start = (start + 1) % capacity
        }
    }

    private mutating func trim(before cutoff: TimeInterval) {
        while count > 0, storage[start].time < cutoff {
            start = (start + 1) % capacity
            count -= 1
        }
        // The oldest remaining sample has no visible predecessor.
        if count > 0, !storage[start].startsSegment {
            storage[start].startsSegment = true
        }
    }
}
