import Testing
@testable import PerfMoonKit

@Suite("Time series")
struct TimeSeriesTests {
    @Test("A gap longer than 2.5 expected intervals starts a new segment")
    func gapStartsSegment() {
        var series = TimeSeries()
        series.append(time: 0, value: 1, expectedInterval: 1)
        series.append(time: 1, value: 2, expectedInterval: 1)
        series.append(time: 3.4, value: 3, expectedInterval: 1)
        series.append(time: 6, value: 4, expectedInterval: 1)
        let samples = series.allSamples()
        #expect(samples.map(\.startsSegment) == [true, false, false, true])
    }

    @Test("The gap rule uses the later sample's interval, so 1 s → 5 s is continuous")
    func intervalChangeIsNotAGap() {
        var series = TimeSeries()
        series.append(time: 0, value: 1, expectedInterval: 1)
        series.append(time: 1, value: 1, expectedInterval: 1)
        series.append(time: 6, value: 1, expectedInterval: 5)
        series.append(time: 8, value: 1, expectedInterval: 2)
        #expect(series.allSamples().map(\.startsSegment) == [true, false, false, false])
    }

    @Test("Explicit breaks split the line even when samples are close together")
    func explicitBreak() {
        var series = TimeSeries()
        series.append(time: 0, value: 1, expectedInterval: 1)
        series.markBreak()
        series.append(time: 1, value: 1, expectedInterval: 1)
        #expect(series.allSamples().map(\.startsSegment) == [true, true])
    }

    @Test("History keeps at most 15 minutes and never exceeds capacity")
    func bounded() {
        var series = TimeSeries(retention: 900, capacity: 1024)
        for second in 0..<3000 {
            series.append(time: Double(second), value: Double(second), expectedInterval: 1)
        }
        #expect(series.count <= 901)
        #expect(series.allSamples().first!.time >= 3000 - 1 - 900)
        #expect(series.last?.time == 2999)

        var tiny = TimeSeries(retention: 10_000, capacity: 8)
        for second in 0..<20 { tiny.append(time: Double(second), value: 0, expectedInterval: 1) }
        #expect(tiny.count == 8)
        #expect(tiny.allSamples().map(\.time) == (12..<20).map(Double.init))
    }

    @Test("Samples that go back in time are ignored")
    func monotonic() {
        var series = TimeSeries()
        series.append(time: 10, value: 1, expectedInterval: 1)
        series.append(time: 9, value: 2, expectedInterval: 1)
        series.append(time: 10, value: 3, expectedInterval: 1)
        #expect(series.count == 1)
    }
}

@Suite("Downsampling")
struct DownsamplerTests {
    @Test("A full 15-minute window at 1 s stays within the ~180 vertex budget and keeps extremes")
    func budgetAndExtremes() {
        var samples: [HistorySample] = []
        for second in 0..<900 {
            let value: Float = second == 451 ? 100 : (second == 452 ? -100 : Float(second % 7))
            samples.append(HistorySample(time: Double(second), value: value, startsSegment: second == 0))
        }
        let points = Downsampler.points(from: samples, start: 0, end: 900)
        #expect(points.count <= 182)
        #expect(points.contains { $0.value == 100 })
        #expect(points.contains { $0.value == -100 })
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.time <= $1.time })
    }

    @Test("Buckets never span a break, so points on both sides keep different segments")
    func segmentsAreNotBridged() {
        var samples: [HistorySample] = []
        for second in 0..<900 where !(300..<600).contains(second) {
            samples.append(HistorySample(time: Double(second), value: 1, startsSegment: second == 0 || second == 600))
        }
        let points = Downsampler.points(from: samples, start: 0, end: 900)
        let before = points.filter { $0.time < 300 }
        let after = points.filter { $0.time >= 600 }
        #expect(Set(before.map(\.segment)) == [0])
        #expect(Set(after.map(\.segment)) == [1])
    }

    @Test("Short windows return raw samples with segment indices")
    func rawWhenSmall() {
        let samples = [
            HistorySample(time: 0, value: 1, startsSegment: true),
            HistorySample(time: 1, value: 2, startsSegment: false),
            HistorySample(time: 5, value: 3, startsSegment: true),
        ]
        let points = Downsampler.points(from: samples, start: 0, end: 60)
        #expect(points.map(\.segment) == [0, 0, 1])
    }

    @Test("Level runs merge equal levels and stop at breaks")
    func levelRuns() {
        let samples = [
            HistorySample(time: 0, value: 0, startsSegment: true),
            HistorySample(time: 2, value: 0, startsSegment: false),
            HistorySample(time: 4, value: 1, startsSegment: false),
            HistorySample(time: 6, value: 1, startsSegment: false),
            HistorySample(time: 20, value: 2, startsSegment: true),
        ]
        let runs = Downsampler.levelRuns(from: samples, end: 100)
        #expect(runs.map(\.level) == [0, 1, 2])
        #expect(runs.map(\.segment) == [0, 0, 1])
        #expect(runs[0].end == 4)
        #expect(runs[1].end == 8)
    }
}

@Suite("Formatting")
struct FormatTests {
    @Test("Menu bar strings never exceed four characters")
    func compactWidths() {
        for value in stride(from: 0.0, through: 100, by: 0.05) {
            #expect(Format.percent(value).count <= 4)
        }
        for value in stride(from: 0.0, through: 199, by: 0.01) {
            #expect(Format.wattsCompact(value).count <= 4, "\(value)")
        }
        for value in stride(from: -20.0, through: 110, by: 0.1) {
            #expect(Format.temperatureCompact(value, unit: .celsius).count <= 4)
            #expect(Format.temperatureCompact(value, unit: .fahrenheit).count <= 4)
        }
        for value in stride(from: 0.0, through: 64 * Format.gibibyte, by: Format.gibibyte / 37) {
            #expect(Format.bytesCompact(value).count <= 4, "\(value)")
        }
    }

    @Test("Rounding edges switch format without producing five characters")
    func roundingEdges() {
        #expect(Format.wattsCompact(9.94) == "9.9W")
        #expect(Format.wattsCompact(9.96) == "10W")
        #expect(Format.wattsCompact(128.4) == "128W")
        #expect(Format.watts(99.96) == "100 W")
        #expect(Format.percent(0) == "0%")
        #expect(Format.percent(0.3) == "<1%")
        #expect(Format.temperature(-20.2, unit: .celsius) == "\u{2212}20 °C")
        #expect(Format.temperature(-0.3, unit: .celsius) == "0 °C")
        #expect(Format.frequency(0.86) == "860 MHz")
    }
}
