import PerfMoonKit
import SwiftUI

/// Ten entries in the existing panel card's body: ranks 1–5 left, 6–10 right.
/// Geometry is supplied by the unchanged memory summary, never by process names.
struct PanelProcessColumns: View {
    let snapshot: ProcessMemorySnapshot

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        if snapshot.entries.isEmpty {
            Text(statusText)
                .font(.pmCaption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            GeometryReader { geometry in
                HStack(spacing: 14) {
                    column(0..<5, height: geometry.size.height / 5)
                    column(5..<10, height: geometry.size.height / 5)
                }
            }
            // Same state language as ReadingText: paused reads secondary, stale fades.
            .foregroundStyle(paused ? .secondary : .primary)
            .opacity(snapshot.status == .stale ? 0.45 : 1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Top 10 processes by memory")
        }
    }

    private func column(_ indices: Range<Int>, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(indices, id: \.self) { index in
                if index < snapshot.entries.count {
                    let entry = snapshot.entries[index]
                    HStack(spacing: 4) {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 11, alignment: .trailing)
                        Text(entry.name)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.bytes(entry.memoryBytes))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .fixedSize()
                    }
                    .frame(height: height)
                    .contentShape(Rectangle())
                    .help(rowHelp(entry))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(index + 1). \(entry.name)")
                    .accessibilityValue("\(Format.spokenBytes(entry.memoryBytes)), process ID \(entry.pid)")
                } else {
                    Color.clear.frame(height: height).accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func rowHelp(_ entry: ProcessMemoryEntry) -> String {
        var text = "\(entry.name) · PID \(entry.pid) · \(Format.bytes(entry.memoryBytes))"
        if snapshot.status == .stale, let timestamp = snapshot.timestamp {
            text += " · Last updated \(Format.clockTime(timestamp))"
        }
        return text
    }

    private var statusText: String {
        switch snapshot.status {
        case .unavailable(let reason): reason.message
        case .warming: ReadingStatus.warmingMessage
        case .valid, .stale: "No processes to show"
        }
    }
}

/// Top memory-consuming processes as supplied by the data layer (already sorted and limited).
/// The view never enumerates processes itself.
struct ProcessMemoryList: View {
    let snapshot: ProcessMemorySnapshot
    /// Panel style: tighter rows, no PID column (PID stays in the tooltip and VoiceOver).
    var compact = false
    var showsPID = true

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        if snapshot.entries.isEmpty {
            statusLine
        } else {
            VStack(spacing: compact ? 2 : 0) {
                if !compact {
                    header
                }
                let largest = snapshot.entries.map(\.memoryBytes).max() ?? 1
                ForEach(Array(snapshot.entries.enumerated()), id: \.element.id) { index, entry in
                    ProcessMemoryRow(
                        rank: index + 1,
                        entry: entry,
                        fraction: largest > 0 ? entry.memoryBytes / largest : 0,
                        compact: compact,
                        showsPID: showsPID && !compact
                    )
                    if !compact, index < snapshot.entries.count - 1 {
                        Divider()
                    }
                }
            }
            .opacity(snapshot.status == .stale ? 0.45 : 1)
            .helpIfPresent(staleHelp)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Top processes by memory")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16, height: 1)
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            if showsPID {
                Text("PID").frame(width: 56, alignment: .trailing)
            }
            Text("Memory").frame(width: 72, alignment: .trailing)
        }
        .font(.pmCaption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusLine: some View {
        let message: String = switch snapshot.status {
        case .unavailable(let reason): reason.message
        case .warming: ReadingStatus.warmingMessage
        case .valid, .stale: "No processes to show"
        }
        Text(message)
            .font(.pmCaption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, compact ? 2 : 8)
            .accessibilityLabel("Top processes: \(message)")
    }

    private var staleHelp: String? {
        guard snapshot.status == .stale, let timestamp = snapshot.timestamp else { return nil }
        return "Last updated \(Format.clockTime(timestamp))"
    }
}

private struct ProcessMemoryRow: View {
    let rank: Int
    let entry: ProcessMemoryEntry
    let fraction: Double
    let compact: Bool
    let showsPID: Bool

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .trailing)
            Text(entry.name)
                .font(.pmBody)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsPID {
                Text(String(entry.pid))
                    .font(.pmCaptionNumber)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            Text(Format.bytes(entry.memoryBytes))
                .font(.pmBodyNumber)
                .fixedSize()
                .frame(minWidth: compact ? 58 : 72, alignment: .trailing)
        }
        .foregroundStyle(paused ? .secondary : .primary)
        .padding(.horizontal, 6)
        .padding(.vertical, compact ? 3 : 5)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 5)
                    .fill(Palette.memory.opacity(0.10))
                    .frame(width: max(6, proxy.size.width * min(1, fraction)))
            }
        }
        .help("\(entry.name) · PID \(entry.pid)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.name)
        .accessibilityValue("\(Format.spokenBytes(entry.memoryBytes)), process ID \(entry.pid)")
    }
}
