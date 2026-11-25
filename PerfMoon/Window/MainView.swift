// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

struct MainActions {
    var togglePause: () -> Void
    var readDiskHealth: (String) async -> DiskHealthReport?
    var openSettings: (SettingsTab) -> Void
    var setCoreInspectorVisible: (Bool) -> Void
    var setProcessListVisible: (Bool, Page) -> Void
}

/// Time window and refresh trigger shared by every chart on a page.
struct ChartContext {
    let range: TimeRange
    let end: TimeInterval
    let revision: Int
}

struct MainView: View {
    let model: DashboardModel
    @Bindable var settings: AppSettings
    let machine: MachineInfo
    let actions: MainActions

    @Environment(\.isLiveData) private var isLiveData
    @State private var pageWidth: CGFloat = 800

    var body: some View {
        NavigationSplitView {
            List(selection: pageSelection) {
                ForEach(Page.allCases) { page in
                    Label(page.title, systemImage: page.symbol)
                        .tag(page)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                if settings.showsStatistics {
                    StatisticsPage(page: settings.selectedPage, model: model, context: context, width: pageWidth,
                                   setCoreInspectorVisible: actions.setCoreInspectorVisible, preferredInterface: $settings.networkInterface)
                } else {
                    detail
                }
            }
                .onGeometryChange(for: CGFloat.self) { max(0, $0.size.width - PageMetrics.totalHorizontalPadding) } action: { pageWidth = $0 }
                .navigationTitle(settings.selectedPage.title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
        }
        .environment(\.monitorPaused, model.run.userPaused)
        .frame(minWidth: 760, minHeight: 560)
    }

    /// Live data needs no subtitle unless paused; preview fixtures always say so.
    private var subtitle: String {
        switch (isLiveData, model.run.userPaused) {
        case (true, true): "Paused"
        case (true, false): ""
        case (false, true): "Paused · Simulated Data"
        case (false, false): "Simulated Data"
        }
    }

    private var pageSelection: Binding<Page?> {
        Binding(
            get: { settings.selectedPage },
            set: { if let page = $0 { settings.selectedPage = page } }
        )
    }

    private var context: ChartContext {
        ChartContext(range: settings.timeRange, end: model.time, revision: model.historyRevision)
    }

    @ViewBuilder
    private var detail: some View {
        switch settings.selectedPage {
        case .overview:
            OverviewPage(model: model, context: context, machine: machine, width: pageWidth) { settings.selectedPage = $0 }
        case .cpu:
            CPUPage(model: model, context: context, width: pageWidth, setCoreInspectorVisible: actions.setCoreInspectorVisible, openSensorSettings: { actions.openSettings(.cpu) }, settings: settings, setProcessListVisible: { actions.setProcessListVisible($0, .cpu) })
        case .gpu:
            GPUPage(model: model, context: context)
        case .memory:
            MemoryPage(model: model, context: context, width: pageWidth, setProcessListVisible: { actions.setProcessListVisible($0, .memory) })
        case .disk:
            DiskPage(model: model, context: context, width: pageWidth, setProcessListVisible: { actions.setProcessListVisible($0, .disk) },
                     readDiskHealth: actions.readDiskHealth)
        case .network:
            NetworkPage(model: model, context: context, preferredInterface: $settings.networkInterface)
        case .power:
            PowerPage(model: model, context: context)
        }
    }

    private var rangePicker: some View {
        Picker("Time Range", selection: $settings.timeRange) {
            ForEach(TimeRange.allCases) { range in
                Text(range.shortTitle).tag(range).accessibilityLabel(range.spokenTitle)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if pageWidth < 690 {
                Menu {
                    rangePicker.pickerStyle(.inline)
                } label: {
                    Label(settings.timeRange.shortTitle, systemImage: "clock").labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Time Range")
                .help("Time Range")
            } else {
                rangePicker.pickerStyle(.segmented).help("Time Range")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $settings.showsStatistics) {
                Label("Statistics", systemImage: "tablecells").labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .help(settings.showsStatistics ? "Show charts (⌥⌘I)" : "Show range statistics (⌥⌘I)")

        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            let paused = model.run.userPaused
            Button(action: actions.togglePause) {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
            }
            .help(paused ? "Resume Monitoring (⇧⌘P)" : "Pause Monitoring (⇧⌘P)")
        }
    }
}

extension Page {
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .power: "bolt"
        }
    }

    /// Preserve the existing page shortcuts when adding Network after Disk.
    var shortcutKey: Character {
        switch self {
        case .overview: "1"
        case .cpu: "2"
        case .gpu: "3"
        case .memory: "4"
        case .power: "5"
        case .disk: "6"
        case .network: "7"
        }
    }
}

// MARK: - Page scaffolding

/// Shared padding also determines the width reported to adaptive detail pages.
private enum PageMetrics {
    static let padding: CGFloat = 20
    static let totalHorizontalPadding = padding * 2
}

/// Defer charts and tables below the viewport when changing the sidebar selection.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(PageMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A row of summary statistics separated by hairlines.
struct StatStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 0) {
                content
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatBlock<Value: View, Detail: View>: View {
    let label: String
    var isFirst = false
    @ViewBuilder var value: Value
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.pmCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            value
            detail
        }
        .padding(.leading, isFirst ? 0 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) {
            if !isFirst { ColumnDivider().accessibilityHidden(true) }
        }
        .accessibilityElement(children: .combine)
    }
}

extension StatBlock where Detail == EmptyView {
    init(label: String, isFirst: Bool = false, @ViewBuilder value: () -> Value) {
        self.init(label: label, isFirst: isFirst, value: value) { EmptyView() }
    }
}

/// A titled chart card.
struct ChartCard<Header: View, Chart: View>: View {
    let title: String
    var height: CGFloat = 140
    @ViewBuilder var header: Header
    @ViewBuilder var chart: Chart

    var body: some View {
        Card(stretches: true) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: title) { header }
                chart
                    .frame(height: height)
            }
        }
    }
}

extension ChartCard where Header == EmptyView {
    init(title: String, height: CGFloat = 140, @ViewBuilder chart: () -> Chart) {
        self.init(title: title, height: height, header: { EmptyView() }, chart: chart)
    }
}
