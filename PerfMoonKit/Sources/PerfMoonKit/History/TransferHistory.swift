// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum TransferHistoryKey: Hashable, Sendable {
    case disk(UInt64)
    case network
}

public struct TransferTotal: Equatable, Sendable {
    public fileprivate(set) var incoming: Double = 0
    public fileprivate(set) var outgoing: Double = 0
    public fileprivate(set) var recordedSeconds: TimeInterval = 0
}

/// Prefix sums of measured counter windows, independent of chart decimation.
/// Inside a boundary sample, attribute its bytes in proportion to the overlap.
struct TransferHistory {
    private struct Interval {
        let start: TimeInterval
        let end: TimeInterval
        let total: TransferTotal
    }

    private var intervals: ArraySlice<Interval> = []
    private var beforeFirst = TransferTotal()

    mutating func append(_ rates: TransferRates) {
        let input = rates.incoming, output = rates.outgoing
        guard input.status == .valid, output.status == .valid,
              let end = input.timestamp, end.isFinite, end == output.timestamp,
              input.window.isFinite, input.window > 0, input.window == output.window,
              let incoming = input.value, incoming.isFinite, incoming >= 0,
              let outgoing = output.value, outgoing.isFinite, outgoing >= 0 else { return }

        var start = end - input.window
        var measuredSeconds = input.window
        if let previous = intervals.last {
            guard end > previous.end else { return }
            // The scheduler timestamps the request just before the collector reads
            // its monotonic clock. Align adjacent edges despite small IPC jitter.
            if abs(start - previous.end) < 0.05 {
                start = previous.end
            } else if start < previous.end {
                start = previous.end
                measuredSeconds = end - start
            }
        }
        var total = intervals.last?.total ?? beforeFirst
        total.incoming += incoming * measuredSeconds
        total.outgoing += outgoing * measuredSeconds
        total.recordedSeconds += end - start
        intervals.append(Interval(start: start, end: end, total: total))

        let cutoff = end - TimeRange.sixHours.seconds
        while let first = intervals.first, first.end <= cutoff {
            beforeFirst = first.total
            intervals.removeFirst()
        }
        if intervals.startIndex >= max(256, intervals.count) {
            intervals = ArraySlice(Array(intervals))
        }
    }

    func total(from start: TimeInterval, to end: TimeInterval) -> TransferTotal? {
        guard start.isFinite, end.isFinite, start < end, let last = intervals.last else { return nil }
        let lower = prefix(at: max(start, last.end - TimeRange.sixHours.seconds))
        let upper = prefix(at: end)
        let covered = upper.recordedSeconds - lower.recordedSeconds
        guard covered > 0 else { return nil }
        return TransferTotal(incoming: upper.incoming - lower.incoming, outgoing: upper.outgoing - lower.outgoing,
                             recordedSeconds: covered)
    }

    private func prefix(at time: TimeInterval) -> TransferTotal {
        var low = intervals.startIndex, high = intervals.endIndex
        while low < high {
            let mid = low + (high - low) / 2
            if intervals[mid].end <= time { low = mid + 1 } else { high = mid }
        }
        let previous = low == intervals.startIndex ? beforeFirst : intervals[low - 1].total
        guard low < intervals.endIndex else { return previous }
        let interval = intervals[low]
        guard time > interval.start else { return previous }
        let elapsed = time - interval.start
        let fraction = elapsed / (interval.end - interval.start)
        return TransferTotal(incoming: previous.incoming + (interval.total.incoming - previous.incoming) * fraction,
                             outgoing: previous.outgoing + (interval.total.outgoing - previous.outgoing) * fraction,
                             recordedSeconds: previous.recordedSeconds + elapsed)
    }
}
