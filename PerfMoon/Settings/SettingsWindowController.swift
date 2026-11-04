import AppKit
import PerfMoonKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case cpu
    case performance
    case dataSources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .cpu: "CPU"
        case .performance: "Performance"
        case .dataSources: "Data Sources"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .cpu: "cpu"
        case .performance: "gauge.with.dots.needle.33percent"
        case .dataSources: "list.bullet.rectangle"
        }
    }

    static let contentSize = NSSize(width: 600, height: 580)

    var demand: Demand? {
        switch self {
        case .cpu: .sensorTable
        case .performance: .performancePage
        default: nil
        }
    }
}

private final class SettingsTabController: NSTabViewController {
    var onSelect: ((SettingsTab) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let identifier = tabViewItem?.identifier as? String, let tab = SettingsTab(rawValue: identifier) {
            onSelect?(tab)
        }
    }
}

/// Keep an unvisited tab to an AppKit placeholder. Its SwiftUI graph is created
/// only when AppKit first requests the selected page's view.
@MainActor
private final class LazySettingsPageController: NSViewController {
    private let size: NSSize
    private let makeContent: () -> NSViewController

    init(size: NSSize, makeContent: @escaping () -> NSViewController) {
        self.size = size
        self.makeContent = makeContent
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let content = makeContent()
        addChild(content)
        content.view.frame = container.bounds
        content.view.autoresizingMask = [.width, .height]
        container.addSubview(content.view)
        view = container
    }
}

/// Toolbar-style Settings with five pages. Collects sensor previews and self-usage only while visible.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private unowned let app: AppModel
    private let tabs = SettingsTabController()
    private var supports: [SettingsTab: SupportModel] = [:]
    private var observer: Int?
    private var activeDemand: Demand?
    private var isClosing = false
    private(set) var isLive = false
    var loadedPageCount: Int { tabs.children.filter(\.isViewLoaded).count }
    private(set) var currentTab: SettingsTab = .general
    var onClose: (() -> Void)?

    init(app: AppModel) {
        self.app = app
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for tab in SettingsTab.allCases {
            let support = SupportModel()
            supports[tab] = support
            let page = LazySettingsPageController(size: SettingsTab.contentSize) {
                let content = SettingsPage(tab: tab, app: app, support: support)
                let hosting = NSHostingController(rootView: AppEnvironment(app: app) { content })
                hosting.sizingOptions = []
                return hosting
            }
            page.title = tab.title
            let item = NSTabViewItem(viewController: page)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(SettingsTab.contentSize)
        window.contentMinSize = SettingsTab.contentSize
        window.contentMaxSize = SettingsTab.contentSize
        window.center()
        super.init(window: window)
        window.delegate = self
        tabs.onSelect = { [weak self] tab in self?.didSelect(tab) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(tab: SettingsTab?) {
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabs.selectedTabViewItemIndex = index
            didSelect(tab)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        updateLiveness()
    }

    private func didSelect(_ tab: SettingsTab) {
        currentTab = tab
        updateLiveness()
    }

    private func updateLiveness() {
        let visible = !isClosing && window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
        isLive = visible
        // General contains preferences only. A hidden page's model is frozen so
        // even visited tabs retain their local UI state without rendering updates.
        let observesData = visible && currentTab != .general
        if observesData, observer == nil {
            observer = app.engine.addObserver { [weak self] engine in
                guard let self else { return }
                self.supports[self.currentTab]?.apply(engine, includeCatalog: self.currentTab == .cpu)
            }
        } else if !observesData, let observer {
            app.engine.removeObserver(observer)
            self.observer = nil
        }
        if observesData { supports[currentTab]?.apply(app.engine, includeCatalog: currentTab == .cpu) }
        let wanted = visible ? currentTab.demand : nil
        guard wanted != activeDemand else { return }
        if let activeDemand { app.engine.setDemand(activeDemand, active: false) }
        activeDemand = wanted
        if let wanted { app.engine.setDemand(wanted, active: true) }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateLiveness() }
    func windowDidMiniaturize(_ notification: Notification) { updateLiveness() }
    func windowDidDeminiaturize(_ notification: Notification) { updateLiveness() }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        if let observer { app.engine.removeObserver(observer) }
        observer = nil
        if let activeDemand { app.engine.setDemand(activeDemand, active: false) }
        activeDemand = nil
        isLive = false
        window?.makeFirstResponder(nil)
        window?.contentViewController = nil
        window?.toolbar = nil
        window?.contentView = nil
        DispatchQueue.main.async { [self] in withExtendedLifetime(self) {} }
        onClose?()
    }
}

private struct SettingsPage: View {
    let tab: SettingsTab
    let app: AppModel
    let support: SupportModel

    var body: some View {
        Group {
            switch tab {
            case .general:
                GeneralSettingsPage(settings: app.settings)
            case .menuBar:
                MenuBarSettingsPage(settings: app.settings, support: support, history: app.engine.history)
            case .cpu:
                CPUSettingsPage(settings: app.settings, support: support)
            case .performance:
                PerformanceSettingsPage(settings: app.settings, support: support)
            case .dataSources:
                DataSourcesSettingsPage(support: support) { app.engine.retry($0) }
            }
        }
        .frame(width: SettingsTab.contentSize.width, height: SettingsTab.contentSize.height)
    }
}
