// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

struct DiskHealthCard: View {
    let drives: [DiskDriveSnapshot]
    let read: (String) async -> DiskHealthReport?
    @State private var selection: DiskDriveSnapshot?

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Drive Health")
                if drives.isEmpty {
                    Text("No drives available").font(.pmBody).foregroundStyle(.secondary)
                }
                ForEach(drives) { drive in
                    HStack(spacing: 8) {
                        Text(drive.name).font(.pmBody).lineLimit(1).truncationMode(.middle)
                        Text(drive.id).font(.pmCaptionNumber).foregroundStyle(.secondary)
                        Spacer()
                        Button("View SMART Data…") { selection = drive }
                            .accessibilityHint("Shows health data for \(drive.name), \(drive.id)")
                    }
                }
            }
        }
        .sheet(item: $selection) { drive in DiskHealthSheet(drive: drive, read: read) }
    }
}

private struct DiskHealthSheet: View {
    let drive: DiskDriveSnapshot
    let read: (String) async -> DiskHealthReport?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLiveData) private var isLiveData
    @Environment(\.temperatureUnit) private var temperatureUnit
    @State private var report: DiskHealthReport?
    @State private var loading = true
    @State private var request = 0
    @State private var showsRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drive Health").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text([report?.model ?? drive.name, drive.id, report?.bus].compactMap { $0 }.joined(separator: " · "))
                    .font(.pmBody).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let report {
                        fields(report)
                    } else if !isLiveData {
                        Text("SMART data is available while monitoring a real drive.")
                    } else if loading {
                        HStack { ProgressView().controlSize(.small); Text("Reading SMART data…") }
                    } else {
                        Text("Couldn’t read health data for \(drive.id). Check that the drive and the collector are connected.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            Divider()
            HStack {
                if let date = report?.readAt {
                    Text("Read at \(date.formatted(date: .omitted, time: .standard))")
                        .font(.pmCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { loading = true; request += 1 }
                    .disabled(loading || !isLiveData)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520, height: 492)
        .task(id: request) {
            let result = isLiveData ? await read(drive.id) : nil
            guard !Task.isCancelled else { return }
            report = result
            loading = false
        }
    }

    @ViewBuilder private func fields(_ report: DiskHealthReport) -> some View {
        reading("SMART status", report.status ?? "Not reported")
            .fontWeight(.semibold)
        if report.attributes.isEmpty {
            Text("macOS did not report detailed SMART attributes for this drive or connection.")
                .font(.pmBody).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                if let celsius = report.temperatureCelsius {
                    reading("Temperature", Format.temperature(celsius, unit: temperatureUnit))
                }
                counterRow("PERCENTAGE_USED", title: "Estimated endurance used", unit: "%", report: report)
                counterRow("AVAILABLE_SPARE", title: "Available spare", unit: "%", report: report)
                counterRow("AVAILABLE_SPARE_THRESHOLD", title: "Spare threshold", unit: "%", report: report)
                counterRow("CRITICAL_WARNING", title: "Critical warning flags", report: report)
                if let count = report.counter("DATA_UNITS_READ") {
                    reading("Lifetime data read", Format.transferBytes(Double(count) * 512_000))
                }
                if let count = report.counter("DATA_UNITS_WRITTEN") {
                    reading("Lifetime data written", Format.transferBytes(Double(count) * 512_000))
                }
                counterRow("HOST_READ_COMMANDS", title: "Host read commands", report: report)
                counterRow("HOST_WRITE_COMMANDS", title: "Host write commands", report: report)
                counterRow("CONTROLLER_BUSY_TIME", title: "Controller busy time", unit: " min", report: report)
                counterRow("POWER_ON_HOURS", title: "Power-on time", unit: " h", report: report)
                counterRow("POWER_CYCLES", title: "Power cycles", report: report)
                counterRow("UNSAFE_SHUTDOWNS", title: "Unsafe shutdowns", report: report)
                counterRow("MEDIA_ERRORS", title: "Media and data integrity errors", report: report)
                counterRow("NUM_ERROR_INFO_LOG_ENTRIES", title: "Error log entries", report: report)
            }
            Divider()
            DisclosureGroup("All SMART attributes (\(report.attributes.count))", isExpanded: $showsRaw) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(report.attributes.keys.sorted(), id: \.self) { key in
                        fieldRow(key, report.attributes[key] ?? "")
                    }
                }
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private func counterRow(_ name: String, title: String, unit: String = "", report: DiskHealthReport) -> some View {
        if let value = report.counter(name) { reading(title, String(value) + unit) }
    }

    private func reading(_ label: String, _ value: String) -> some View {
        fieldRow(label, value)
            .font(.pmBody)
    }

    private func fieldRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
