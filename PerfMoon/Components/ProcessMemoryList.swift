// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

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

/// Expanded rankings share a single scan across the panel and all detail pages.
struct ProcessRankingCard: View {
    let snapshot: ProcessMemorySnapshot
    var showsPID = true
    let setVisible: (Bool) -> Void
    @State private var expanded = false
    @State private var ranking: ProcessRanking

    init(snapshot: ProcessMemorySnapshot, initialRanking: ProcessRanking, showsPID: Bool = true,
         setVisible: @escaping (Bool) -> Void) {
        self.snapshot = snapshot
        self.showsPID = showsPID
        self.setVisible = setVisible
        _ranking = State(initialValue: initialRanking)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Top 10 Processes", subtitle: expanded ? nil : ranking.title) {
                    Button(expanded ? "Hide" : "Show") { expanded.toggle() }
                        .controlSize(.small)
                        .accessibilityLabel(expanded ? "Hide Top 10 Processes" : "Show Top 10 Processes")
                }
                if expanded {
                    Picker("Rank processes by", selection: $ranking) {
                        ForEach(ProcessRanking.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    ProcessMemoryList(snapshot: snapshot, ranking: ranking, showsPID: showsPID)
                    HStack {
                        if ranking == .cpu { Text("100% = one core") }
                        if ranking == .diskRead || ranking == .diskWrite { Text("Across all disks") }
                        Spacer()
                        if snapshot.inaccessibleProcessCount > 0 {
                            Text("\(snapshot.inaccessibleProcessCount) restricted by macOS")
                        }
                    }
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
                }
            }
            .onChange(of: expanded) { _, value in setVisible(value) }
            .onAppear { if expanded { setVisible(true) } }
            .onDisappear { setVisible(false) }
        }
    }
}

private extension ProcessRanking {
    func format(_ value: Double) -> String {
        switch self {
        case .memory: Format.bytes(value)
        case .cpu: "\(Int(value.rounded()))%"
        case .diskRead, .diskWrite: Format.transferRate(value)
        }
    }

    var color: Color {
        switch self {
        case .cpu: Palette.cpu
        case .memory: Palette.memory
        case .diskRead: Palette.incoming
        case .diskWrite: Palette.outgoing
        }
    }
}

/// Top memory-consuming processes as supplied by the data layer (already sorted and limited).
/// The view never enumerates processes itself.
struct ProcessMemoryList: View {
    let snapshot: ProcessMemorySnapshot
    var ranking: ProcessRanking = .memory
    private var entries: [ProcessMemoryEntry] { snapshot.entries(for: ranking) }
    /// Panel style: tighter rows, no PID column (PID stays in the tooltip and VoiceOver).
    var compact = false
    var showsPID = true

    @Environment(\.monitorPaused) private var paused

    var body: some View {
        if entries.isEmpty {
            statusLine
        } else {
            VStack(spacing: compact ? 2 : 0) {
                if !compact {
                    header
                }
                let largest = entries.first?.value(for: ranking) ?? 1
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    ProcessMemoryRow(
                        rank: index + 1,
                        entry: entry,
                        ranking: ranking,
                        fraction: largest > 0 ? entry.value(for: ranking) / largest : 0,
                        compact: compact,
                        showsPID: showsPID && !compact
                    )
                    if !compact, index < entries.count - 1 {
                        Divider()
                    }
                }
            }
            .opacity(snapshot.status == .stale ? 0.45 : 1)
            .helpIfPresent(staleHelp)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Top processes by \(ranking.title)")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16, height: 1)
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            if showsPID {
                Text("PID").frame(width: 56, alignment: .trailing)
            }
            Text(ranking.title).frame(width: 84, alignment: .trailing)
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
        case .valid, .stale:
            if ranking != .memory && snapshot.rateWindow == nil { "Measuring the first interval…" }
            else if ranking == .diskRead { "No disk reads in this interval" }
            else if ranking == .diskWrite { "No disk writes in this interval" }
            else { "No processes to show" }
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
    let ranking: ProcessRanking
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
            Text(ranking.format(entry.value(for: ranking)))
                .font(.pmBodyNumber)
                .fixedSize()
                .frame(minWidth: compact ? 58 : 84, alignment: .trailing)
        }
        .foregroundStyle(paused ? .secondary : .primary)
        .padding(.horizontal, 6)
        .padding(.vertical, compact ? 3 : 5)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 5)
                    .fill(ranking.color.opacity(0.10))
                    .frame(width: max(6, proxy.size.width * min(1, fraction)))
            }
        }
        .help("\(entry.name) · PID \(entry.pid)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.name)
        .accessibilityValue("\(ranking.format(entry.value(for: ranking))), process ID \(entry.pid)")
    }
}
