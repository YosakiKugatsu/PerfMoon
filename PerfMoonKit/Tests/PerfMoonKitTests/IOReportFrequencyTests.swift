// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonNative
import Testing

@Suite("IOReport frequency table")
struct IOReportFrequencyTests {
    @Test("Preserves the non-monotonic M4 GPU clock slots")
    func m4GPUFrequencySlots() {
        // An excerpt of the M4 pmgr voltage-states9 frequency slots in Hz.
        let rawFrequencies: [UInt32] = [0, 338_000_000, 618_000_000, 796_000_000,
                                      928_000_000, 952_000_000, 1_056_000_000, 1_053_000_000]
        var bytes: [UInt8] = []
        for frequency in rawFrequencies {
            withUnsafeBytes(of: frequency.littleEndian) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: [0, 0, 0, 0]) // Voltage is not decoded.
        }
        var decoded = [Double](repeating: 0, count: rawFrequencies.count)
        let count = pm_report_decode_frequency_table(bytes, bytes.count, &decoded, decoded.count)
        #expect(count == 7)
        #expect(Array(decoded.prefix(count)) == [0.338, 0.618, 0.796, 0.928, 0.952, 1.056, 1.053])
    }
}
