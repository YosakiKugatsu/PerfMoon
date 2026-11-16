// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

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
    private var memoryProcessListVisible = false
    private(set) var isLive = false
    var onClose: (() -> Void)?

    static let autosaveName = "PerfMoonMainWindow"

    init(app: AppModel, reusing reusableWindow: NSWindow? = nil) {
        self.app = app
        let model = DashboardModel(snapshot: app.engine.snapshot)
        self.model = model

        let actions = MainActions(
            togglePause: { [unowned app] in app.togglePause() },
            openSettings: { [unowned app] tab in app.openSettings(tab: tab) },
            setMemoryProcessListVisible: { [unowned app] visible in app.setMainMemoryProcessListVisible(visible) }
        )
        let root = AppEnvironment(app: app) {
            MainView(model: model, settings: app.settings, machine: app.engine.core.machine, actions: actions)
        }
        let hosting = NSHostingController(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []

        let window = reusableWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Rebuilding content must not overwrite the saved frame with temporary
        // sizing. Re-enable autosave after normal bounds have been restored.
        window.setFrameAutosaveName("")
        window.contentViewController = hosting
        window.title = "PerfMoon"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1040, height: 720))
        // Restore normal bounds against the current displays, including after a
        // full-screen close. A hidden shell's current frame may be out of date.
        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        super.init(window: window)
        shouldCascadeWindows = false
        window.setFrameAutosaveName(Self.autosaveName)
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

    func setMemoryProcessListVisible(_ visible: Bool) {
        guard !isClosing else { return }
        memoryProcessListVisible = visible
        updateProcessDemand()
    }

    private func updateProcessDemand() {
        app.engine.setDemand(.windowMemoryProcesses, active: isLive && app.settings.selectedPage == .memory && memoryProcessListVisible)
    }

    // MARK: Liveness

    private func updateLiveness() {
        guard let window else { return }
        let visible = !isClosing && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        guard visible != isLive else { return }
        isLive = visible
        app.engine.setDemand(.coreHistory, active: visible)
        updateProcessDemand()
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
        updateProcessDemand()
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
        app.engine.setDemand(.coreHistory, active: false)
        app.engine.setDemand(.windowMemoryProcesses, active: false)
        app.engine.core.discardCoreHistory()
        if isLive {
            if let observer { app.engine.removeObserver(observer) }
            observer = nil
            if let demandedPage { app.engine.setDemand(.window(demandedPage), active: false) }
            demandedPage = nil
            isLive = false
        }
        // Remove ownership bridges in the close callback, while AppKit can
        // process view removal. Keep the controller alive until close returns.
        window?.makeFirstResponder(nil)
        window?.contentViewController = nil
        window?.toolbar = nil
        window?.contentView = nil
        // Detach before onClose can open a new controller on the same shell.
        window?.delegate = nil
        window = nil
        DispatchQueue.main.async { [self] in withExtendedLifetime(self) {} }
        onClose?()
    }
}
