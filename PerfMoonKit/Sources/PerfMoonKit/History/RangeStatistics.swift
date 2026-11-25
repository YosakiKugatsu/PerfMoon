// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Describes the individual valid observations in a selected time window.
public struct RangeStatistics: Equatable, Sendable {
    public let count: Int
    public let average: Double
    public let minimum: Double
    public let maximum: Double
    public let p95: Double
    public let firstTime: Double
    public let lastTime: Double

    init?(values: [Float], first: Double?, last: Double?) {
        guard !values.isEmpty, let first, let last else { return nil }
        let ordered = values.sorted()
        count = ordered.count
        average = values.reduce(0.0) { $0 + Double($1) } / Double(count)
        minimum = Double(ordered[0])
        maximum = Double(ordered[count - 1])
        p95 = Double(ordered[count - 1 - count / 20])
        firstTime = first
        lastTime = last
    }
}

/// Chart envelopes omit interior observations. Save those evicted from the
/// recent ring in lossless blocks, decoded only when statistics are requested.
struct StatisticsArchive: Sendable {
    private struct Block: Sendable {
        let first: Double
        let last: Double
        let count: Int
        let bytes: Data
        let compressed: Bool

        init(times: [Double], values: [Float]) {
            first = times[0]
            last = times[times.count - 1]
            count = times.count
            var raw = times.withUnsafeBytes { Data($0) }
            values.withUnsafeBytes { raw.append(contentsOf: $0) }
            if let packed = try? (raw as NSData).compressed(using: .lz4), packed.length < raw.count {
                bytes = packed as Data
                compressed = true
            } else {
                bytes = raw
                compressed = false
            }
        }

        func collect(in range: ClosedRange<Double>, into add: (Double, Float) -> Void) {
            guard last >= range.lowerBound, first <= range.upperBound else { return }
            let raw: Data
            if compressed {
                guard let decoded = try? (bytes as NSData).decompressed(using: .lz4) else { return }
                raw = decoded as Data
            } else { raw = bytes }
            raw.withUnsafeBytes { buffer in
                for i in 0..<count {
                    let t = buffer.loadUnaligned(fromByteOffset: i * 8, as: Double.self)
                    if range.contains(t) {
                        add(t, buffer.loadUnaligned(fromByteOffset: count * 8 + i * 4, as: Float.self))
                    }
                }
            }
        }
    }

    private var blocks: ArraySlice<Block> = []
    private var times: [Double] = []
    private var values: [Float] = []

    var bufferBytes: Int {
        blocks.reduce(0) { $0 + $1.bytes.count } + times.capacity * 8 + values.capacity * 4
    }

    mutating func append(_ sample: HistorySample) {
        times.append(sample.time)
        values.append(sample.value)
        if times.count == 256 {
            blocks.append(Block(times: times, values: values))
            times.removeAll(keepingCapacity: true)
            values.removeAll(keepingCapacity: true)
        }
    }

    mutating func expire(before cutoff: Double) {
        while let first = blocks.first, first.last < cutoff { blocks.removeFirst() }
        if blocks.startIndex >= 16 && blocks.startIndex >= blocks.count {
            blocks = ArraySlice(Array(blocks))
        }
        if let last = times.last, last < cutoff {
            times.removeAll(keepingCapacity: true)
            values.removeAll(keepingCapacity: true)
        }
    }

    func collect(in range: ClosedRange<Double>, into add: (Double, Float) -> Void) {
        for block in blocks { block.collect(in: range, into: add) }
        for i in times.indices where range.contains(times[i]) { add(times[i], values[i]) }
    }
}
