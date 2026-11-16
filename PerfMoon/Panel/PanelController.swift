// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import PerfMoonKit
import SwiftUI

/// NSPopover with a system background. The hosting view is created on open and released on close,
/// so nothing in the panel observes data while it is hidden.
@MainActor
final class PanelController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private unowned let app: AppModel
    private var model: DashboardModel?
    private var observer: Int?
    /// Last expansion state reported by the Memory card.
    private var processListOnScreen = false
    /// True while this panel holds the process-list demand.
    private var requestsProcesses = false

    init(app: AppModel) {
        self.app = app
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func toggle(from button: NSStatusBarButton) {
        if popover.isShown {
            close()
        } else {
            show(from: button)
        }
    }

    func show(from button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        let model = DashboardModel(snapshot: app.engine.snapshot)
        self.model = model
        let actions = PanelActions(
            togglePause: { [unowned app] in app.togglePause() },
            openWindow: { [weak self, unowned app] page in
                self?.close()
                app.openMainWindow(page: page)
            },
            openSettings: { [weak self, unowned app] in
                self?.close()
                app.openSettings(tab: nil)
            },
            retryStopped: { [unowned app] in app.engine.retryStopped() },
            useCPUMax: { [unowned app] in app.settings.temperatureSource = .cpuMax },
            setProcessListVisible: { [weak self] visible in self?.setProcessListVisible(visible) },
            close: { [weak self] in self?.close() }
        )
        let root = AppEnvironment(app: app) {
            PanelView(model: model, machine: app.engine.core.machine, actions: actions)
        }
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.appearance = NSApp.appearance

        observer = app.engine.addObserver { [weak model] engine in
            model?.apply(engine.snapshot)
        }
        app.engine.setDemand(.popover, active: true)
        syncProcessDemand()

        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func setProcessListVisible(_ visible: Bool) {
        processListOnScreen = visible
        syncProcessDemand()
    }

    /// Only an open panel with an expanded Memory card requests processes.
    private func syncProcessDemand() {
        let wanted = processListOnScreen && observer != nil
        guard wanted != requestsProcesses else { return }
        requestsProcesses = wanted
        app.engine.setDemand(.memoryProcesses, active: wanted)
    }

    func popoverDidClose(_ notification: Notification) {
        if let observer { app.engine.removeObserver(observer) }
        observer = nil
        processListOnScreen = false
        syncProcessDemand()
        app.engine.setDemand(.popover, active: false)
        popover.contentViewController = nil
        model = nil
    }
}

/// Injects settings-driven environment values shared by every surface.
struct AppEnvironment<Content: View>: View {
    let app: AppModel
    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.historyStore, app.engine.history)
            .environment(\.temperatureUnit, app.settings.temperatureUnit)
            .environment(\.sensorNames, app.sensorNames)
            .environment(\.coreSensorKeys, app.coreSensorKeys)
            .environment(\.isLiveData, app.settings.isLiveData)
    }
}
