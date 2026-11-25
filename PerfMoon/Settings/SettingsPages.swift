// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import PerfMoonKit
import SwiftUI

// MARK: - General

struct GeneralSettingsPage: View {
    @Bindable var settings: AppSettings
    @Environment(\.isLiveData) private var isLiveData

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            } footer: {
                if !isLiveData {
                    Text("Preview builds don't register a login item.")
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Continuous Collection", isOn: $settings.continuousHistory)
            } footer: {
                Text("Keep all chart histories while PerfMoon runs, including with windows closed or the screen locked. Pause and system sleep leave gaps.")
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Temperature Unit", selection: $settings.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                Picker("Update Interval", selection: $settings.updateInterval) {
                    ForEach(UpdateInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Applies while PerfMoon is open. Background updates run every 2 s or slower.")
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Menu Bar

struct MenuBarSettingsPage: View {
    @Bindable var settings: AppSettings
    let support: SupportModel
    let history: HistoryStore

    var body: some View {
        Form {
            Section {
                MenuBarPreview(settings: settings, support: support, history: history)
            }
            Section {
                Picker("Left Metric", selection: $settings.menuTopLine) {
                    ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0) }
                }
                Picker("Right Metric", selection: $settings.menuBottomLine) {
                    ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show Trend", isOn: $settings.showsMiniGraph)
            } footer: {
                Text("The trend appears in a separate menu bar item and shows the four latest CPU samples. CPU Temperature uses the source chosen in CPU settings.")
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The real glyph, rendered on light and dark menu bar swatches.
private struct MenuBarPreview: View {
    let settings: AppSettings
    let support: SupportModel
    let history: HistoryStore

    var body: some View {
        HStack(spacing: 16) {
            if let image {
                swatch(image: image, dark: false)
                swatch(image: image, dark: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu bar preview")
        .accessibilityValue(content?.spoken ?? "")
    }

    private var content: StatusGlyph.Content? {
        guard let snapshot = support.snapshot else { return nil }
        return StatusGlyph.content(
            snapshot: snapshot,
            history: history,
            top: settings.menuTopLine,
            bottom: settings.menuBottomLine,
            showsGraph: settings.showsMiniGraph,
            unit: settings.temperatureUnit,
            height: 22
        )
    }

    private var image: NSImage? {
        content.map(StatusGlyph.image)
    }

    private func swatch(image: NSImage, dark: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Image(systemName: "wifi").font(.system(size: 13))
                if settings.showsMiniGraph, let content {
                    Image(nsImage: StatusGlyph.trendImage(content))
                        .renderingMode(.template)
                        .padding(.horizontal, 5)
                        .frame(height: 26)
                        .background(.fill.tertiary, in: Capsule())
                }
                Image(nsImage: image)
                    .renderingMode(.template)
                    .padding(.horizontal, 5)
                    .frame(height: 26)
                    .background(.fill.tertiary, in: Capsule())
                Text("9:41").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(dark ? Color.white : Color.black)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(dark ? Color(white: 0.17) : Color(white: 0.94), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            Text(dark ? "Dark" : "Light")
                .font(.pmCaption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - CPU

struct CPUSettingsPage: View {
    @Bindable var settings: AppSettings
    let support: SupportModel

    @State private var search = ""
    @State private var category: SensorCategory?
    @Environment(\.temperatureUnit) private var unit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Temperature Source")
                    .font(.headline)
                Text("Used for the CPU temperature in the menu bar, the panel, and charts. Changing it starts a new temperature history.")
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                SearchField(text: $search, prompt: "Search Sensors")
                Picker("Category", selection: $category) {
                    Text("All Categories").tag(SensorCategory?.none)
                    Divider()
                    ForEach(SensorCategory.allCases) { category in
                        Text(category.title).tag(SensorCategory?.some(category))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            VStack(spacing: 0) {
                SensorTableHeader()
                List(selection: selection) {
                    Section("Summary") {
                        SensorRow(id: TemperatureSource.cpuMax.storageValue, name: "CPU Max", category: "CPU", key: "—",
                                  reading: aggregate { $0.max() ?? 0 }, isCurrent: settings.temperatureSource == .cpuMax)
                        SensorRow(id: TemperatureSource.cpuAverage.storageValue, name: "CPU Average", category: "CPU", key: "—",
                                  reading: aggregate { $0.reduce(0, +) / Double($0.count) }, isCurrent: settings.temperatureSource == .cpuAverage)
                    }
                    Section("Sensors") {
                        ForEach(filtered) { sensor in
                            SensorRow(
                                id: TemperatureSource.sensor(sensor.id).storageValue,
                                name: sensor.info.name,
                                category: sensor.info.category.title,
                                key: sensor.id,
                                reading: sensor.reading,
                                isCurrent: settings.temperatureSource == .sensor(sensor.id)
                            )
                        }
                        if filtered.isEmpty {
                            Text("No Matching Sensors")
                                .foregroundStyle(.secondary)
                                .padding(.leading, SensorColumns.check + 8)
                                .listRowInsets(EdgeInsets(top: 2, leading: SensorColumns.inset, bottom: 2, trailing: SensorColumns.inset))
                                .selectionDisabled()
                        }
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            }

            SourceDetail(settings: settings, support: support)
        }
        .padding(20)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { settings.temperatureSource.storageValue },
            set: { value in
                if let value { settings.temperatureSource = TemperatureSource(storageValue: value) }
            }
        )
    }

    private var filtered: [SensorReading] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return support.catalog.filter { sensor in
            if let category, sensor.info.category != category { return false }
            if query.isEmpty { return true }
            return sensor.info.name.lowercased().contains(query)
                || sensor.id.lowercased().contains(query)
                || sensor.info.category.title.lowercased().contains(query)
        }
    }

    private func aggregate(_ combine: ([Double]) -> Double) -> MetricReading {
        let cpu = support.catalog.filter { $0.info.category == .cpu }
        let values = cpu.compactMap { $0.reading.shownValue }
        guard !values.isEmpty else {
            return cpu.first?.reading ?? .pending(.celsius)
        }
        return MetricReading(value: combine(values), unit: .celsius, status: .valid, quality: .derived)
    }
}

private enum SensorColumns {
    /// Leading and trailing row inset. The header adds the 1 pt list border so its
    /// columns line up with the rows.
    static let inset: CGFloat = 10
    static let border: CGFloat = 1
    static let check: CGFloat = 14
    static let category: CGFloat = 70
    static let key: CGFloat = 48
    static let current: CGFloat = 64
}

private struct SensorTableHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: SensorColumns.check, height: 1)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Category").frame(width: SensorColumns.category, alignment: .leading)
            Text("ID").frame(width: SensorColumns.key, alignment: .leading)
            Text("Current").frame(width: SensorColumns.current, alignment: .trailing)
        }
        .font(.pmCaption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, SensorColumns.inset + SensorColumns.border)
        // 24 pt in total: 20 pt of title aligned to the bottom, then 4 pt above the list.
        .frame(height: 20, alignment: .bottom)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }
}

private struct SensorRow: View {
    let id: String
    let name: String
    let category: String
    let key: String
    let reading: MetricReading
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tint)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: SensorColumns.check)
            Text(name)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(name)
            Text(category)
                .foregroundStyle(.secondary)
                .frame(width: SensorColumns.category, alignment: .leading)
            Text(key)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: SensorColumns.key, alignment: .leading)
            TemperatureText(reading: reading, font: .pmBodyNumber, emphasis: .primary)
                .frame(width: SensorColumns.current, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 2, leading: SensorColumns.inset, bottom: 2, trailing: SensorColumns.inset))
        .tag(id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Details for the chosen source, including where it comes from and how it maps to cores.
private struct SourceDetail: View {
    let settings: AppSettings
    let support: SupportModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.pmBody.weight(.medium))
                Text(detail)
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if support.cpuTemperature.unavailableReason == .sensorMissing, case .sensor = settings.temperatureSource {
                Button("Use CPU Max") { settings.temperatureSource = .cpuMax }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.fill.quinary, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private var sensor: SensorReading? {
        guard case .sensor(let id) = settings.temperatureSource else { return nil }
        return support.catalog.first { $0.id == id }
    }

    private var title: String {
        switch settings.temperatureSource {
        case .cpuMax: "CPU Max"
        case .cpuAverage: "CPU Average"
        case .sensor(let id):
            if let sensor { "\(sensor.info.name) · \(id) · \(sensor.info.category.title)" } else { id }
        }
    }

    private var detail: String {
        switch settings.temperatureSource {
        case .cpuMax:
            return "Highest reading among all CPU sensors. Read from System Sensors (SMC)."
        case .cpuAverage:
            return "Average of all CPU sensors. Read from System Sensors (SMC)."
        case .sensor:
            var text = "Read from System Sensors (SMC)."
            if let core = sensor?.info.mappedCore {
                text += " Matched to core \(core.label) by a community-maintained table that Apple doesn't publish."
            }
            if support.cpuTemperature.unavailableReason == .sensorMissing {
                text += " This sensor is no longer reported. Your choice is kept."
            }
            return text
        }
    }
}

/// Native NSSearchField.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel(prompt)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

// MARK: - Performance

struct PerformanceSettingsPage: View {
    let settings: AppSettings
    let support: SupportModel

    var body: some View {
        let interval = settings.updateInterval.rawValue
        Form {
            Section {
                LabeledContent("CPU") {
                    ReadingText(reading: support.selfUsage.cpu, format: Format.precisePercent)
                }
                LabeledContent("Memory Footprint") {
                    ReadingText.bytes(support.selfUsage.footprint)
                }
            } header: {
                Text("PerfMoon")
            } footer: {
                Text("Includes the app, root collector, and active power sampler. Measured every 10 s. CPU is a share of one core.")
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Open panel or window", value: every(interval))
                LabeledContent("Background", value: every(max(interval, SchedulePlanner.backgroundFloor)))
                LabeledContent("Temperatures", value: every(max(interval, SchedulePlanner.temperatureFloor)))
                LabeledContent("Sensor list preview", value: every(max(interval, SchedulePlanner.catalogFloor)))
            } header: {
                Text("Update Schedule")
            } footer: {
                Text("Nothing is collected while monitoring is paused or the Mac is asleep.")
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func every(_ seconds: TimeInterval) -> String {
        "Every \(Format.interval(seconds))"
    }
}

// MARK: - Data Sources

struct DataSourcesSettingsPage: View {
    let support: SupportModel
    let settings: AppSettings
    let authorize: () -> Void
    let retry: (SourceID) -> Void

    @Environment(\.isLiveData) private var isLiveData

    var body: some View {
        Form {
            if isLiveData {
                LabeledContent("Collector") {
                    if settings.collectorConnected {
                        Label("Running as root", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        Button(settings.authorizingCollector ? "Authorizing…" : "Authorize…", action: authorize)
                            .disabled(settings.authorizingCollector)
                    }
                }
            }
            Section {
                ForEach(support.sources) { status in
                    SourceRow(status: status, retry: retry)
                }
            } footer: {
                Text(isLiveData
                    ? "Each source describes where a value comes from and how it's measured."
                    : "This preview shows simulated readings. Each source describes where a value will come from and how it's measured.")
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SourceRow: View {
    let status: SourceStatus
    let retry: (SourceID) -> Void

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 6) {
                ForEach(status.id.metrics) { metric in
                    HStack(spacing: 8) {
                        Text(metric.name)
                        Spacer(minLength: 8)
                        if let unavailable = metric.unavailable {
                            Text(unavailable.message).foregroundStyle(.secondary)
                        } else {
                            Text(metric.quality?.title ?? "")
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text(windowTitle(metric.window))
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .trailing)
                        }
                    }
                    .font(.pmCaption)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(status.id.title)
                        Text("(\(status.id.technicalName))").foregroundStyle(.secondary)
                    }
                    Text(statusLine)
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if showsRetry {
                    Button("Retry") { retry(status.id) }
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var showsRetry: Bool {
        switch status.phase {
        case .stopped: true
        case .unavailable(let reason): reason.isRetryable
        default: false
        }
    }

    private var dotColor: Color {
        switch status.phase {
        case .active: .green
        case .recovering: .yellow
        case .stopped: .red
        case .unavailable: .gray
        case .idle: .gray.opacity(0.5)
        }
    }

    private var statusLine: String {
        let updated = status.lastUpdated.map { "Last updated \(Format.clockTime($0))" }
        switch status.phase {
        case .active:
            let cadence = status.interval.map { "Every \(Format.interval($0))" } ?? "On demand"
            return [cadence, updated].compactMap { $0 }.joined(separator: " · ")
        case .idle:
            return "Waiting for the first reading"
        default:
            return [status.reason?.message, updated].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private func windowTitle(_ window: MetricDescriptor.Window?) -> String {
        switch window {
        case .instant: "Instant reading"
        case .updateInterval: "Over each update"
        case nil: ""
        }
    }
}
