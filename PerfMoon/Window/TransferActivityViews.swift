// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

/// A shared pair of directional readings, with the same legend as its chart.
struct TransferPair: View {
    let rates: TransferRates
    let incoming: String
    let outgoing: String
    var font: Font = .pmStatNumber
    var operations = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            column(incoming, reading: rates.incoming, color: Palette.incoming, dash: [])
            ColumnDivider()
            column(outgoing, reading: rates.outgoing, color: Palette.outgoing, dash: [4, 3])
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func column(_ label: String, reading: MetricReading, color: Color, dash: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LegendKey(title: label, color: color, dash: dash)
            ReadingText(reading: reading, format: { operations ? Format.rate($0) : Format.transferRate($0) }, font: font)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(ReadingText.spoken(reading) { operations ? Format.spokenRate($0) : Format.transferRate($0) })
    }
}

struct TransferChart: View {
    let incoming: SeriesKey
    let outgoing: SeriesKey
    let labels: (String, String)
    let context: ChartContext
    var operations = false
    var compact = false
    var reason: UnavailableReason?

    var body: some View {
        HistoryChart(series: [
            ChartSeries(key: incoming, name: labels.0, color: Palette.incoming, style: .lineAndArea),
            ChartSeries(key: outgoing, name: labels.1, color: Palette.outgoing, dash: [4, 3]),
        ], scale: operations ? .operations : .throughput, range: context.range, end: context.end, revision: context.revision,
        compact: compact, accessibilityName: "\(labels.0) and \(labels.1) history", unavailableReason: reason)
    }
}

private struct PeriodTransferTotals: View {
    let device: TransferHistoryKey?
    let incoming: String
    let outgoing: String
    let context: ChartContext
    @Environment(\.historyStore) private var history

    var body: some View {
        let seconds = context.range.seconds
        let total = device.flatMap { history?.transferTotal(for: $0, from: context.end - seconds, to: context.end) }
        let recorded = Duration.seconds((total?.recordedSeconds ?? 0).rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(context.range.shortTitle) totals").font(.pmCaption.weight(.semibold))
                if let total {
                    if total.recordedSeconds < seconds - UpdateInterval.five.rawValue {
                        Text("\(recorded) recorded").font(.pmCaption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No samples in range").font(.pmCaption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            amount(incoming, total?.incoming)
            amount(outgoing, total?.outgoing)
        }
        .accessibilityElement(children: .combine)
        .help("Bytes transferred during sampled intervals in the last \(context.range.spokenTitle). Recorded \(recorded).")
    }

    private func amount(_ label: String, _ value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(.pmCaption).foregroundStyle(.secondary)
            Text(value.map(Format.transferBytes) ?? Format.placeholder).font(.pmBodyNumber)
        }
        .fixedSize()
        .help(value.map { "\($0.formatted(.number.precision(.fractionLength(0)))) bytes" } ?? "No samples in range")
    }
}

/// Inline readings used where a larger chart or stat block would crowd the panel.
struct InlineTransfer: View {
    let rates: TransferRates
    let labels: (String, String)
    var font: Font = .pmCaptionNumber

    var body: some View {
        HStack(spacing: 12) {
            item(labels.0, image: "arrow.down", color: Palette.incoming, reading: rates.incoming)
            item(labels.1, image: "arrow.up", color: Palette.outgoing, reading: rates.outgoing)
        }
    }

    private func item(_ label: String, image: String, color: Color, reading: MetricReading) -> some View {
        HStack(spacing: 3) {
            Image(systemName: image).font(.pmCaption.weight(.semibold)).foregroundStyle(color)
            ReadingText(reading: reading, format: Format.transferRate, font: font)
        }
        .fixedSize()
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(ReadingText.spoken(reading, Format.transferRate))
    }
}

struct DiskActivityView: View {
    let activity: DiskActivity?
    let status: ReadingStatus
    let context: ChartContext
    @State private var operations = false

    var body: some View {
        if let activity {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Disk Activity") {
                    Picker("Disk activity metric", selection: $operations) {
                        Text("Throughput").tag(false)
                        Text("IOPS").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
                }
                let rates = operations ? activity.operations : activity.bytes
                TransferPair(rates: rates, incoming: "Read", outgoing: "Write", operations: operations)
                TransferChart(incoming: .diskActivity(activity.id, operations ? .readIOPS : .read),
                              outgoing: .diskActivity(activity.id, operations ? .writeIOPS : .write),
                              labels: ("Read", "Write"), context: context, operations: operations,
                              reason: rates.incoming.unavailableReason)
                    .frame(height: 118)
                PeriodTransferTotals(device: .disk(activity.id), incoming: "Read", outgoing: "Written", context: context)
            }
        } else {
            HStack {
                Text("Disk Activity").font(.pmCardTitle)
                Spacer()
                Text(statusText).font(.pmCaption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch status {
        case .warming: ReadingStatus.warmingMessage
        case .unavailable(let reason): reason.message
        default: "No device counters available"
        }
    }
}

extension NetworkInterfaceInfo {
    var displayTitle: String { name == id ? id : "\(name) · \(id)" }
}

struct NetworkPage: View {
    let model: DashboardModel
    let context: ChartContext
    @Binding var preferredInterface: String

    var body: some View {
        let network = model.network
        PageScroll {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    CardHeader(title: "Traffic", subtitle: network.selected?.displayTitle) {
                        NetworkInterfacePicker(interfaces: network.interfaces, preferredInterface: $preferredInterface)
                    }
                    TransferPair(rates: network.rates, incoming: "Download", outgoing: "Upload", font: .pmCardNumber)
                    TransferChart(incoming: .networkDownload, outgoing: .networkUpload,
                                  labels: ("Download", "Upload"), context: context, reason: network.rates.incoming.unavailableReason)
                        .frame(height: 180)
                    PeriodTransferTotals(device: network.selected == nil ? nil : .network, incoming: "Downloaded",
                                         outgoing: "Uploaded", context: context)
                }
            }
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "Interface Lifetime Totals", subtitle: network.selected?.id)
                        .help("Link-layer bytes since the interface counters started or last reset.")
                    HStack(spacing: 16) {
                        total("Received", value: network.receivedBytes)
                        ColumnDivider()
                        total("Sent", value: network.sentBytes)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func total(_ title: String, value: UInt64?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.pmCaption).foregroundStyle(.secondary)
            Text(value.map { Format.transferBytes(Double($0)) } ?? Format.placeholder).font(.pmStatNumber)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct NetworkInterfacePicker: View {
    let interfaces: [NetworkInterfaceInfo]
    @Binding var preferredInterface: String

    var body: some View {
        Menu {
            Picker("Interface", selection: $preferredInterface) {
                Text("Automatic (physical interface)").tag("")
                if !preferredInterface.isEmpty, !interfaces.contains(where: { $0.id == preferredInterface }) {
                    Text("\(preferredInterface) · Disconnected").tag(preferredInterface)
                }
                Section("Hardware") {
                    ForEach(interfaces.filter(\.isHardware)) { link in Text(link.displayTitle).tag(link.id) }
                }
                Section("Other Interfaces") {
                    ForEach(interfaces.filter { !$0.isHardware }) { link in Text(link.displayTitle).tag(link.id) }
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(preferredInterface.isEmpty ? "Automatic" : preferredInterface, systemImage: "network")
        }
        .fixedSize()
        .controlSize(.small)
        .help("Select the interface for the window, panel, and menu bar")
        .accessibilityLabel("Network interface")
    }
}
