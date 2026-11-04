import AppKit
import PerfMoonKit
import SwiftUI

/// The main window receives data only while it is visible and not occluded or minimized.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private unowned let app: AppModel
    private let model: DashboardModel
    private var observer: Int?
    private var demandedPage: Page?
    private var isClosing = false
    private(set) var isLive = false
    var onClose: (() -> Void)?

    static let autosaveName = "PerfMoonMainWindow"

    init(app: AppModel) {
        self.app = app
        let model = DashboardModel(snapshot: app.engine.snapshot)
        self.model = model

        let actions = MainActions(
            togglePause: { [unowned app] in app.togglePause() },
            openSettings: { [unowned app] tab in app.openSettings(tab: tab) }
        )
        let root = AppEnvironment(app: app) {
            MainView(model: model, settings: app.settings, machine: app.engine.core.machine, actions: actions)
        }
        let hosting = NSHostingController(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "PerfMoon"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.tabbingMode = .disallowed
        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        updateLiveness()
    }

    func pageDidChange() {
        guard isLive else { return }
        updateDemand()
    }

    // MARK: Liveness

    private func updateLiveness() {
        guard let window else { return }
        let visible = !isClosing && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        guard visible != isLive else { return }
        isLive = visible
        if visible {
            observer = app.engine.addObserver { [weak model] engine in
                model?.apply(engine.snapshot)
            }
            updateDemand()
        } else {
            if let observer { app.engine.removeObserver(observer) }
            observer = nil
            if let demandedPage { app.engine.setDemand(.window(demandedPage), active: false) }
            demandedPage = nil
        }
    }

    private func updateDemand() {
        let page = app.settings.selectedPage
        guard page != demandedPage else { return }
        if let demandedPage { app.engine.setDemand(.window(demandedPage), active: false) }
        demandedPage = page
        app.engine.setDemand(.window(page), active: true)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateLiveness() }
    func windowDidMiniaturize(_ notification: Notification) { updateLiveness() }
    func windowDidDeminiaturize(_ notification: Notification) { updateLiveness() }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        if isLive {
            if let observer { app.engine.removeObserver(observer) }
            observer = nil
            if let demandedPage { app.engine.setDemand(.window(demandedPage), active: false) }
            demandedPage = nil
            isLive = false
        }
        window?.contentViewController = nil
        onClose?()
    }
}
