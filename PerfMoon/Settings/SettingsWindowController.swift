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

    var contentSize: NSSize {
        switch self {
        case .general: NSSize(width: 600, height: 300)
        case .menuBar: NSSize(width: 600, height: 400)
        case .cpu: NSSize(width: 600, height: 580)
        case .performance: NSSize(width: 600, height: 400)
        case .dataSources: NSSize(width: 600, height: 580)
        }
    }

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

/// Toolbar-style Settings with five pages. Collects sensor previews and self-usage only while visible.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private unowned let app: AppModel
    private let tabs = SettingsTabController()
    private let support = SupportModel()
    private var observer: Int?
    private var activeDemand: Demand?
    var isLive: Bool { observer != nil }
    private(set) var currentTab: SettingsTab = .general
    var onClose: (() -> Void)?

    init(app: AppModel) {
        self.app = app
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for tab in SettingsTab.allCases {
            let page = SettingsPage(tab: tab, app: app, support: support)
            let hosting = NSHostingController(rootView: AppEnvironment(app: app) { page })
            hosting.title = tab.title
            hosting.sizingOptions = []
            hosting.view.frame.size = tab.contentSize
            let item = NSTabViewItem(viewController: hosting)
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
        window.setContentSize(SettingsTab.general.contentSize)
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
        resize(to: tab.contentSize)
        updateLiveness()
    }

    private func updateLiveness() {
        let visible = window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
        if visible, observer == nil {
            observer = app.engine.addObserver { [weak self] engine in
                guard let self else { return }
                self.support.apply(engine, includeCatalog: self.currentTab == .cpu)
            }
        } else if !visible, let observer {
            app.engine.removeObserver(observer)
            self.observer = nil
        }
        if visible { support.apply(app.engine, includeCatalog: currentTab == .cpu) }
        let wanted = visible ? currentTab.demand : nil
        guard wanted != activeDemand else { return }
        if let activeDemand { app.engine.setDemand(activeDemand, active: false) }
        activeDemand = wanted
        if let wanted { app.engine.setDemand(wanted, active: true) }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateLiveness() }
    func windowDidMiniaturize(_ notification: Notification) { updateLiveness() }
    func windowDidDeminiaturize(_ notification: Notification) { updateLiveness() }

    private func resize(to size: NSSize) {
        guard let window else { return }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var newFrame = window.frame
        newFrame.origin.y += newFrame.height - frame.height
        newFrame.size = frame.size
        window.setFrame(newFrame, display: true, animate: window.isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        if let observer { app.engine.removeObserver(observer) }
        observer = nil
        if let activeDemand { app.engine.setDemand(activeDemand, active: false) }
        activeDemand = nil
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
        .frame(width: tab.contentSize.width, height: tab.contentSize.height)
    }
}
