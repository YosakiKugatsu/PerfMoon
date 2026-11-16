// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

/// One part of physical memory, in bar order from hardest to easiest to reclaim.
/// Reusable sits beside Available because macOS can take it back first.
enum MemoryPart: CaseIterable {
    case wired, compressed, apps, reusable, available

    var title: String {
        switch self {
        case .wired: "Wired"
        case .compressed: "Compressed"
        case .apps: "Apps"
        case .reusable: "Reusable"
        case .available: "Available"
        }
    }

    var help: String {
        switch self {
        case .wired: "Memory the system keeps in RAM. It can't be compressed or reclaimed."
        case .compressed: "Memory macOS has compressed to make room, at its compressed size."
        case .apps: "App Memory not counting Reusable, which is shown separately."
        case .reusable: "Memory apps have released for macOS to reclaim. Still resident and included in Used."
        case .available: "Physical memory not counted in Used, including cached files macOS can reuse."
        }
    }

    /// Spoken name; Apps says what it leaves out.
    var spokenTitle: String {
        self == .apps ? "Apps, not counting Reusable" : title
    }

    fileprivate func bytes(in composition: MemoryComposition) -> Double? {
        switch self {
        case .wired: composition.wired
        case .compressed: composition.compressed
        case .apps: composition.app
        case .reusable: composition.reusable
        case .available: composition.available
        }
    }

    /// The reading behind this part, for its status and unavailable reason.
    fileprivate func reading(in memory: MemorySnapshot) -> MetricReading {
        switch self {
        case .wired: memory.wired
        case .compressed: memory.compressed
        case .apps: memory.app
        case .reusable: memory.reusable
        case .available: memory.available
        }
    }
}

/// Where physical memory goes: a neutral bar split into Wired, Compressed, Apps, Reusable,
/// and Available, with a legend of measured values. Reusable is part of Used, drawn
/// hatched, and is never added to Used or Available. Without a complete breakdown the bar
/// falls back to Used and Available, and the legend shows dashes with their reasons.
struct MemoryCompositionView: View {
    enum Layout {
        /// Popover: 8 pt bar and a two-by-two legend. The unfilled track isn't named or spoken.
        case panel
        /// Main window: 12 pt bar, a legend with Available, and a note about Reusable.
        case window
    }

    let memory: MemorySnapshot
    let layout: Layout

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        let composition = memory.composition
        VStack(alignment: .leading, spacing: layout == .panel ? 8 : 10) {
            Group {
                if let composition {
                    MemoryCompositionBar(composition: composition, dimmed: paused || isStale)
                } else {
                    Meter(fraction: memory.used.shownValue.map { $0 / memory.physical }, color: Palette.memory,
                          height: barHeight)
                }
            }
            .frame(height: barHeight)
            legend(composition)
            if layout == .window, composition?.reusable != nil {
                Text("Reusable: \(MemoryPart.reusable.help)")
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory composition")
        .accessibilityValue(spoken(composition))
    }

    private var barHeight: CGFloat { layout == .panel ? 8 : 12 }

    private var isStale: Bool {
        [memory.used, memory.app, memory.wired, memory.compressed].contains(where: \.isStale)
    }

    @ViewBuilder
    private func legend(_ composition: MemoryComposition?) -> some View {
        switch layout {
        case .panel:
            // Same order as the bar, read left to right, top to bottom.
            VStack(spacing: 3) {
                HStack(spacing: 14) {
                    item(.wired, composition)
                    item(.compressed, composition)
                }
                HStack(spacing: 14) {
                    item(.apps, composition)
                    item(.reusable, composition)
                }
            }
        case .window:
            let parts = MemoryPart.allCases
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    ForEach(parts, id: \.self) { item($0, composition, fills: false) }
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow { ForEach(parts.prefix(3), id: \.self) { item($0, composition, fills: false) } }
                    GridRow { ForEach(parts.suffix(2), id: \.self) { item($0, composition, fills: false) } }
                }
            }
        }
    }

    private func item(_ part: MemoryPart, _ composition: MemoryComposition?, fills: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // Without text, the swatch sits on the baseline and reaches cap height.
            MemorySwatch(part: part)
            Text(part.title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if fills { Spacer(minLength: 4) }
            value(part, composition)
        }
        .font(.pmCaption)
        .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
        .help(part.help)
    }

    @ViewBuilder
    private func value(_ part: MemoryPart, _ composition: MemoryComposition?) -> some View {
        let reading = part.reading(in: memory)
        if let composition, let bytes = part.bytes(in: composition) {
            Text(Format.bytes(bytes))
                .font(.pmCaptionNumber)
                .foregroundStyle(paused ? .secondary : .primary)
                .opacity(reading.isStale || isStale ? 0.45 : 1)
                .fixedSize()
        } else if composition == nil, part != .apps {
            // These mean the same thing without a full breakdown. Apps doesn't: the raw
            // App Memory reading still includes Reusable.
            ReadingText.bytes(reading, font: .pmCaptionNumber)
                .fixedSize()
        } else {
            Text(Format.placeholder)
                .font(.pmCaptionNumber)
                .foregroundStyle(.tertiary)
                .help(missingHelp(part))
        }
    }

    private func missingHelp(_ part: MemoryPart) -> String {
        if part == .reusable { return ReadingText.placeholderHelp(memory.reusable) }
        let missing = [memory.used, memory.app, memory.wired, memory.compressed].first { $0.shownValue == nil }
        return missing.map(ReadingText.placeholderHelp) ?? ReadingStatus.warmingMessage
    }

    private func spoken(_ composition: MemoryComposition?) -> String {
        guard let composition else {
            let used = ReadingText.spoken(memory.used, Format.spokenBytes)
            return "Breakdown not available. Used \(used) of \(Format.wholeGigabytes(memory.physical))"
        }
        // The popover shows only the parts of Used; the main window also names Available.
        let shown = layout == .window ? MemoryPart.allCases : MemoryPart.allCases.filter { $0 != .available }
        let parts = shown.map { part in
            guard let bytes = part.bytes(in: composition) else {
                return "\(part.spokenTitle) \(ReadingText.placeholderHelp(memory.reusable))"
            }
            let detail = part == .reusable ? ", still resident and included in Used" : ""
            return "\(part.spokenTitle) \(Format.spokenBytes(bytes))\(detail)"
        }
        return parts.joined(separator: ", ") + (paused ? ", paused" : isStale ? ", stale" : "")
    }
}

// MARK: - Drawing

/// Neutral fills so pressure colors keep their meaning. Reusable is a hatch over a light
/// fill: the same memory as Apps in spirit, but marked as reclaimable.
private enum MemoryPartStyle {
    static func opacity(_ part: MemoryPart) -> Double {
        switch part {
        case .wired: 0.80
        case .compressed: 0.40
        case .apps: 0.60
        case .reusable: 0.16
        case .available: 0
        }
    }

    static func fill(_ part: MemoryPart, in rect: CGRect, context: GraphicsContext, dim: Double) {
        guard part != .available else { return }
        context.fill(Path(rect), with: .color(.primary.opacity(opacity(part) * dim)))
        if part == .reusable {
            hatch(rect, context: context, color: .primary.opacity(0.55 * dim))
        }
    }

    static func hatch(_ rect: CGRect, context: GraphicsContext, color: Color) {
        var clipped = context
        clipped.clip(to: Path(rect))
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 3
        }
        clipped.stroke(path, with: .color(color), lineWidth: 1)
    }
}

/// Proportional segments over a track that stands for Available. Small gaps separate the
/// parts; a part too thin to see is still listed in the legend.
private struct MemoryCompositionBar: View {
    let composition: MemoryComposition
    let dimmed: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let shape = Path(roundedRect: bounds, cornerRadius: size.height / 2)
            context.fill(shape, with: .style(.fill.tertiary))
            var plot = context
            plot.clip(to: shape)
            let physical = max(1, composition.physical)
            let dim = dimmed ? 0.55 : 1
            var x: CGFloat = 0
            var edges: [CGFloat] = []
            for part in MemoryPart.allCases where part != .available {
                let bytes = max(0, part.bytes(in: composition) ?? 0)
                let width = size.width * CGFloat(bytes / physical)
                guard width > 0 else { continue }
                MemoryPartStyle.fill(part, in: CGRect(x: x, y: 0, width: width, height: size.height), context: plot, dim: dim)
                x += width
                edges.append(x)
            }
            // Cut a gap at each boundary, including where Available begins.
            let gap: CGFloat = size.height >= 12 ? 2 : 1.5
            plot.blendMode = .destinationOut
            for edge in edges where edge > gap && edge < size.width - gap {
                plot.fill(Path(CGRect(x: edge - gap / 2, y: 0, width: gap, height: size.height)), with: .color(.black))
            }
        }
        .overlay {
            if contrast == .increased {
                Capsule().strokeBorder(.separator, lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Legend key drawn like its bar segment.
struct MemorySwatch: View {
    let part: MemoryPart

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let shape = Path(roundedRect: rect, cornerRadius: 2)
            var clipped = context
            clipped.clip(to: shape)
            if part == .available {
                clipped.fill(shape, with: .style(.fill.tertiary))
            } else {
                MemoryPartStyle.fill(part, in: rect, context: clipped, dim: paused ? 0.55 : 1)
            }
        }
        .frame(width: 8, height: 8)
        .overlay {
            if part == .available || part == .reusable {
                RoundedRectangle(cornerRadius: 2).strokeBorder(.separator, lineWidth: 0.5)
            }
        }
        .accessibilityHidden(true)
    }
}
