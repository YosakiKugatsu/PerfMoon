import PerfMoonKit
import SwiftUI

struct MainActions {
    var togglePause: () -> Void
    var openSettings: (SettingsTab) -> Void
    var setMemoryProcessListVisible: (Bool) -> Void
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
            detail
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
            OverviewPage(model: model, context: context, machine: machine) { settings.selectedPage = $0 }
        case .cpu:
            CPUPage(model: model, context: context, openSensorSettings: { actions.openSettings(.cpu) }, settings: settings)
        case .gpu:
            GPUPage(model: model, context: context)
        case .memory:
            MemoryPage(model: model, context: context, setProcessListVisible: actions.setMemoryProcessListVisible)
        case .power:
            PowerPage(model: model, context: context)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Time Range", selection: $settings.timeRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.shortTitle)
                        .tag(range)
                        .accessibilityLabel(range.spokenTitle)
                }
            }
            .pickerStyle(.segmented)
            .help("Time Range")
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
        case .power: "bolt"
        }
    }
}

// MARK: - Page scaffolding

/// Scrolling page with 20 pt margins that reports its usable width.
struct PageScroll<Content: View>: View {
    @Binding var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - 40 } action: { width = $0 }
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
        HStack(spacing: 0) {
            if !isFirst {
                ColumnDivider().padding(.trailing, 14)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.pmCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                value
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
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
