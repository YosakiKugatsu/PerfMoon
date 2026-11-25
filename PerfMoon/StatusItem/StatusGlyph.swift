// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import PerfMoonKit

/// The menu bar glyphs. Both items share one two-rail type system so they read as a family:
///
///     CPU     POWER        CPU          ← label rail: 8.5 pt semibold caps, tracked
///     23%     31W          ▂▅▃▇         ← value rail: 13 pt tabular figures, or bars on 0–100 tracks
///
/// Units are set smaller than the digits, so the number carries the weight and the
/// columns stay narrow. Everything is drawn into template images, so the system tints
/// it for light, dark, and tinted menu bars. Images are rebuilt only when content changes.
enum StatusGlyph {
    /// Fixed column width; fits the widest value ("128W", "100%", "512M") at full size.
    static let metricWidth: CGFloat = 34
    /// Gutter between the two metrics.
    static let metricGap: CGFloat = 10
    static let graphWidth: CGFloat = 26
    /// Bar height for 100%; equal to the value rail's cap height so bars line up with digits.
    static let barMaxHeight: CGFloat = 9
    static let barWidth: CGFloat = 4
    static let barSpacing: CGFloat = 2

    struct Content: Equatable, Sendable {
        var top: String
        var bottom: String
        var topTitle: String
        var bottomTitle: String
        /// Bar heights in device pixels at 2×, oldest first; nil for an empty slot.
        var bars: [Int?]
        var showsGraph: Bool
        var paused: Bool
        var height: CGFloat
        var spoken: String
        var topStale = false
        var bottomStale = false

        var width: CGFloat {
            StatusGlyph.metricWidth * 2 + StatusGlyph.metricGap
        }

        static func == (lhs: Content, rhs: Content) -> Bool {
            lhs.hasSameValues(as: rhs) && lhs.hasSameTrend(as: rhs) && lhs.showsGraph == rhs.showsGraph && lhs.spoken == rhs.spoken
        }

        func hasSameValues(as other: Content) -> Bool {
            top == other.top && bottom == other.bottom && topTitle == other.topTitle
                && bottomTitle == other.bottomTitle && height == other.height && paused == other.paused
                && topStale == other.topStale && bottomStale == other.bottomStale
        }

        func hasSameTrend(as other: Content) -> Bool {
            bars == other.bars && height == other.height && paused == other.paused
        }
    }

    // MARK: Content

    @MainActor
    static func content(
        snapshot: MonitorSnapshot,
        history: HistoryStore,
        top: MenuBarMetric,
        bottom: MenuBarMetric,
        showsGraph: Bool,
        unit: TemperatureUnit,
        height: CGFloat
    ) -> Content {
        let paused = snapshot.run.userPaused
        let topLine = paused ? Format.placeholder : text(for: top, snapshot: snapshot, unit: unit)
        let bottomLine = paused ? Format.placeholder : text(for: bottom, snapshot: snapshot, unit: unit)
        var bars: [Int?] = []
        if showsGraph {
            bars = recentBars(history: history, end: snapshot.time)
        }
        let spoken = paused
            ? "Monitoring paused"
            : [spokenText(for: top, snapshot: snapshot, unit: unit), spokenText(for: bottom, snapshot: snapshot, unit: unit)].joined(separator: ", ")
        return Content(top: topLine, bottom: bottomLine, topTitle: shortTitle(top), bottomTitle: shortTitle(bottom), bars: bars, showsGraph: showsGraph, paused: paused, height: height, spoken: spoken,
                       topStale: reading(for: top, snapshot: snapshot).isStale, bottomStale: reading(for: bottom, snapshot: snapshot).isStale)
    }

    /// Rail labels. Drawn in caps, so every label has the same height.
    private static func shortTitle(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .cpuUsage: "CPU"
        case .gpuUsage: "GPU"
        case .systemPower: "Power"
        case .cpuTemperature: "Temp"
        case .memoryUsed: "RAM"
        case .networkDownload: "↓/s"
        case .networkUpload: "↑/s"
        }
    }

    static func reading(for metric: MenuBarMetric, snapshot: MonitorSnapshot) -> MetricReading {
        switch metric {
        case .cpuUsage: snapshot.cpu.total
        case .gpuUsage: snapshot.gpu.usage
        case .systemPower: snapshot.power.system
        case .cpuTemperature: snapshot.cpu.temperature
        case .memoryUsed: snapshot.memory.used
        case .networkDownload: snapshot.network.rates.incoming
        case .networkUpload: snapshot.network.rates.outgoing
        }
    }

    static func text(for metric: MenuBarMetric, snapshot: MonitorSnapshot, unit: TemperatureUnit) -> String {
        guard let value = reading(for: metric, snapshot: snapshot).shownValue else { return Format.placeholder }
        switch metric {
        case .cpuUsage, .gpuUsage: return Format.percent(value)
        case .systemPower: return Format.wattsCompact(value)
        case .cpuTemperature: return Format.temperatureCompact(value, unit: unit)
        case .memoryUsed: return Format.bytesCompact(value)
        case .networkDownload, .networkUpload: return Format.transferRateCompact(value)
        }
    }

    static func spokenText(for metric: MenuBarMetric, snapshot: MonitorSnapshot, unit: TemperatureUnit) -> String {
        let reading = reading(for: metric, snapshot: snapshot)
        guard let value = reading.shownValue else {
            return "\(metric.title) \(reading.unavailableReason?.message ?? ReadingStatus.warmingMessage)"
        }
        let description: String = switch metric {
        case .cpuUsage, .gpuUsage: "\(metric.title) \(Format.spokenPercent(value))"
        case .systemPower: "\(metric.title) \(Format.spokenWatts(value))"
        case .cpuTemperature: "\(metric.title) \(Format.spokenTemperature(value, unit: unit))"
        case .memoryUsed: "\(metric.title) \(Format.spokenBytes(value))"
        case .networkDownload, .networkUpload: "\(metric.title) \(Format.transferRate(value))"
        }
        return description + (reading.isStale ? ", stale" : "")
    }

    /// The last four CPU samples, oldest first, quantized to the drawn bar's pixels so an
    /// invisible change never causes a redraw. Samples older than a few cycles leave empty slots.
    @MainActor
    static func recentBars(history: HistoryStore, end: TimeInterval) -> [Int?] {
        let recent = history.samples(.cpuTotal, since: end - 30).suffix(4)
        var bars: [Int?] = recent.map { sample in
            Int((CGFloat(min(100, max(0, sample.value))) / 100 * barMaxHeight * 2).rounded())
        }
        while bars.count < 4 { bars.insert(nil, at: 0) }
        return bars
    }

    // MARK: Drawing

    /// Two metrics, each a caps label over its value, both centered on a fixed column.
    @MainActor
    static func image(_ content: Content) -> NSImage {
        let rails = Rails(height: content.height)
        let fade: CGFloat = content.paused ? 0.6 : 1
        let metrics = [(content.topTitle, content.top, content.topStale), (content.bottomTitle, content.bottom, content.bottomStale)]
        // Shape and measure once per changed value; reuse the lines at both backing scales.
        let columns: [(label: InkLine, value: InkLine)] = metrics.map { metric in
            let template = inkTemplate(metric.1)
            return (InkLine(rails.label(metric.0, alpha: Rails.labelAlpha * fade)),
                    InkLine(rails.value(metric.1, fade: fade * (metric.2 ? 0.45 : 1)),
                            measuring: template == metric.1 ? nil : rails.value(template, fade: 1)))
        }
        return templateImage(size: NSSize(width: content.width, height: content.height), description: content.spoken) { _, context, scale in
            for (index, column) in columns.enumerated() {
                let center = CGFloat(index) * (metricWidth + metricGap) + metricWidth / 2
                draw(column.label, centeredAt: center, baseline: rails.labelBaseline, scale: scale, context: context)
                draw(column.value, centeredAt: center, baseline: rails.valueBaseline, scale: scale, context: context)
            }
        }
    }

    /// Recent CPU samples as four bars on faint 0–100 tracks, under the same caps label.
    /// Tracks give the bars a scale, so a low reading reads as low rather than missing.
    @MainActor
    static func trendImage(_ content: Content) -> NSImage {
        let rails = Rails(height: content.height)
        let fade: CGFloat = content.paused ? 0.6 : 1
        let title = InkLine(rails.label("CPU", alpha: Rails.labelAlpha * fade))
        return templateImage(size: NSSize(width: graphWidth, height: content.height), description: "CPU usage trend") { rect, context, scale in
            let barsWidth = barWidth * 4 + barSpacing * 3
            let left = pixelRounded((rect.width - barsWidth) / 2)
            draw(title, centeredAt: left + barsWidth / 2, baseline: rails.labelBaseline, scale: scale, context: context)

            let bottom = rails.valueBaseline
            for index in 0..<4 {
                let x = left + CGFloat(index) * (barWidth + barSpacing)
                let track = CGRect(x: x, y: bottom, width: barWidth, height: barMaxHeight)
                context.setFillColor(NSColor.black.withAlphaComponent(0.2 * fade).cgColor)
                context.addPath(CGPath(roundedRect: track, cornerWidth: 1, cornerHeight: 1, transform: nil))
                context.fillPath()

                guard index < content.bars.count, let pixels = content.bars[index] else { continue }
                let height = min(barMaxHeight, max(1, CGFloat(pixels) / 2))
                let bar = CGRect(x: x, y: bottom, width: barWidth, height: height)
                if content.paused {
                    let outline = bar.insetBy(dx: 0.375, dy: 0.375)
                    context.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
                    context.setLineWidth(0.75)
                    context.addPath(CGPath(roundedRect: outline, cornerWidth: 0.75, cornerHeight: min(0.75, outline.height / 2), transform: nil))
                    context.strokePath()
                } else {
                    context.setFillColor(NSColor.black.cgColor)
                    context.addPath(CGPath(roundedRect: bar, cornerWidth: 1, cornerHeight: min(1, height / 2), transform: nil))
                    context.fillPath()
                }
            }
        }
    }

    // MARK: Type

    @MainActor private enum Fonts {
        static let label = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        static let value = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        static let unit = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    }

    /// Fonts are shared across updates; only height-dependent baselines are recalculated.
    private struct Rails {
        static let labelAlpha: CGFloat = 0.78
        static let unitAlpha: CGFloat = 0.78
        static let placeholderAlpha: CGFloat = 0.6
        /// Values never shrink below this share of their size to fit a column.
        static let minimumScale: CGFloat = 0.85

        let labelFont: NSFont
        let valueFont: NSFont
        let unitFont: NSFont
        let labelBaseline: CGFloat
        let valueBaseline: CGFloat

        @MainActor init(height: CGFloat) {
            labelFont = Fonts.label
            valueFont = Fonts.value
            unitFont = Fonts.unit
            let gap: CGFloat = 2
            let block = valueFont.capHeight + gap + labelFont.capHeight
            valueBaseline = StatusGlyph.pixelRounded((height - block) / 2)
            labelBaseline = StatusGlyph.pixelRounded(valueBaseline + valueFont.capHeight + gap)
        }

        func label(_ title: String, alpha: CGFloat) -> NSAttributedString {
            let text = NSAttributedString(string: title.uppercased(), attributes: [
                .font: labelFont,
                .kern: 0.4,
                .foregroundColor: NSColor.black.withAlphaComponent(alpha),
            ])
            return StatusGlyph.fitted(text, maxWidth: StatusGlyph.metricWidth)
        }

        /// "23%" → 13 pt "23" + 9.5 pt "%". Degrees keep the digit size so "°" sits at cap height.
        func value(_ text: String, fade: CGFloat) -> NSAttributedString {
            // Paused, warming, and unavailable all show a dash at one fixed, quieter strength.
            if text == Format.placeholder {
                return NSAttributedString(string: text, attributes: [
                    .font: valueFont,
                    .foregroundColor: NSColor.black.withAlphaComponent(Rails.placeholderAlpha),
                ])
            }
            var number = text
            var unit = ""
            if let last = text.last, "%WGM°".contains(last) {
                number = String(text.dropLast())
                unit = String(last)
            }
            let isDegree = unit == "°"
            let result = NSMutableAttributedString(string: number, attributes: [
                .font: valueFont,
                .foregroundColor: NSColor.black.withAlphaComponent(fade),
            ])
            if !unit.isEmpty {
                // A hairline between the digits and a smaller unit; none before "°".
                if !isDegree, result.length > 0 {
                    result.addAttribute(.kern, value: 0.6, range: NSRange(location: result.length - 1, length: 1))
                }
                result.append(NSAttributedString(string: unit, attributes: [
                    .font: isDegree ? valueFont : unitFont,
                    .foregroundColor: NSColor.black.withAlphaComponent((isDegree ? 1 : Rails.unitAlpha) * fade),
                ]))
            }
            return StatusGlyph.fitted(result, maxWidth: StatusGlyph.metricWidth)
        }
    }

    /// Scales every font run down, never below `Rails.minimumScale`, until the line fits.
    private static func fitted(_ text: NSAttributedString, maxWidth: CGFloat) -> NSAttributedString {
        let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
        guard width > maxWidth, width > 0 else { return text }
        let scale = max(Rails.minimumScale, maxWidth / width)
        let scaled = NSMutableAttributedString(attributedString: text)
        scaled.enumerateAttribute(.font, in: NSRange(location: 0, length: scaled.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let size = (font.pointSize * scale * 4).rounded(.down) / 4
            scaled.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: size) ?? font, range: range)
        }
        return scaled
    }

    /// A shaped line and the horizontal center of its ink. Ink, not advance, so side bearings
    /// and the labels' trailing tracking don't pull a line off its column center.
    private struct InkLine {
        let line: CTLine
        let inkMidX: CGFloat

        /// `probe` is measured in place of `text` when given; it must have the same layout.
        init(_ text: NSAttributedString, measuring probe: NSAttributedString? = nil) {
            line = CTLineCreateWithAttributedString(text)
            let measured = probe.map { CTLineCreateWithAttributedString($0) } ?? line
            let ink = CTLineGetBoundsWithOptions(measured, .useGlyphPathBounds)
            inkMidX = ink.isNull || ink.width <= 0
                ? CGFloat(CTLineGetTypographicBounds(measured, nil, nil, nil)) / 2
                : ink.midX
        }
    }

    /// Tabular digits share one advance but not one ink box. Values are measured with every
    /// digit set to zero, so a reading changes in place instead of shifting sideways.
    private static func inkTemplate(_ text: String) -> String {
        String(text.map { $0.isASCII && $0.isWholeNumber ? "0" : $0 })
    }

    /// Centers the line's ink on `center`, with its origin on the backing pixel grid.
    private static func draw(_ text: InkLine, centeredAt center: CGFloat, baseline: CGFloat, scale: CGFloat, context: CGContext) {
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: ((center - text.inkMidX) * scale).rounded() / scale, y: baseline)
        CTLineDraw(text.line, context)
    }

    private static func templateImage(size: NSSize, description: String, draw: @escaping (NSRect, CGContext, CGFloat) -> Void) -> NSImage {
        let image = NSImage(size: size)
        // A drawing-handler image is rerun for each menu-bar replicant. Bake both
        // backing scales once per changed value; AppKit can reuse/tint these pixels.
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * CGFloat(scale))),
                pixelsHigh: Int(ceil(size.height * CGFloat(scale))), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            bitmap.size = size
            guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let rect = NSRect(origin: .zero, size: size)
            graphics.cgContext.clear(rect)
            draw(rect, graphics.cgContext, CGFloat(scale))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    private static func pixelRounded(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}
