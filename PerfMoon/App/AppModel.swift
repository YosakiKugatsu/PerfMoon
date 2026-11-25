// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import PerfMoonKit
import SwiftUI
import ServiceManagement

/// Composition root: owns the engine, settings, status item, panel, and windows.
@MainActor
final class AppModel {
    let settings = AppSettings()
    let fixtures = FixtureProvider()
    let collector: RootMetricProvider
    let engine: MonitorEngine
    let statusItem = StatusItemController()
    private(set) lazy var panel = PanelController(app: self)
    var sensorNames: [String: String] { Dictionary(uniqueKeysWithValues: engine.core.sensors.map { ($0.id, $0.name) }) }
    var coreSensorKeys: [Int: String] {
        Dictionary(uniqueKeysWithValues: engine.core.machine.cpuTopology.cores.compactMap { core in
            engine.core.mappedSensor(for: core).map { (core.flatIndex, $0) }
        })
    }
    private var changingLoginItem = false
    private let diagnostics = RuntimeDiagnostics()

    private var mainWindow: MainWindowController?
    // Reuse native chrome only; each open receives fresh content and a model.
    private var mainWindowShell: NSWindow?
    private var settingsWindow: SettingsWindowController?
    private var systemObservers: [NSObjectProtocol] = []
    #if DEBUG
    private(set) var gallery: DesignGalleryController?
    #endif

    init() {
        collector = RootMetricProvider(executable: Bundle.main.executableURL!)
        engine = MonitorEngine(fixtures: fixtures, liveProvider: collector)
    }

    func launch() {
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        settings.onChange = { [weak self] change in self?.settingsChanged(change) }
        if !settings.networkInterface.isEmpty { engine.setNetworkInterface(settings.networkInterface) }
        updateNetworkDemand()
        engine.setDemand(.continuousHistory, active: settings.continuousHistory)
        engine.start(scenario: .typical, interval: settings.updateInterval, temperatureSource: settings.temperatureSource)

        statusItem.onClick = { [weak self] button in self?.panel.toggle(from: button) }
        statusItem.menuProvider = { [weak self] in self?.statusMenu() ?? NSMenu() }
        engine.addObserver { [weak self] engine in
            guard let self else { return }
            if self.settings.isLiveData != engine.isLive {
                self.settings.isLiveData = engine.isLive
            }
            if self.settings.collectorConnected != self.collector.isRootConnected {
                self.settings.collectorConnected = self.collector.isRootConnected
            }
            self.refreshStatusItem()
            if self.diagnostics.isEnabled {
                self.diagnostics.record(engine, collector: self.collector, settingsTab: self.settingsWindow?.isLive == true ? self.settingsWindow?.currentTab.rawValue : nil,
                    details: ["statusWidth": self.statusItem.button?.bounds.width ?? 0,
                              "statusHeight": self.statusItem.button?.bounds.height ?? 0,
                              "glyphHeight": self.statusItem.currentContent?.height ?? 0,
                              "statusItemLength": self.statusItem.itemLength,
                              "statusRedraws": self.statusItem.redrawCount,
                              "settingsLoadedPages": self.settingsWindow?.loadedPageCount ?? 0,
                              "mainWindowRetained": self.mainWindow != nil])
            }
        }

        NSApp.mainMenu = MainMenu.build(app: self)
        observeSystem()

        #if DEBUG
        if DebugLaunchOptions.apply(to: self) { return }
        #endif
        // First run introduces the app; later launches stay in the menu bar until
        // the user requests a window. Reopening the app still opens the window.
        if !collector.isRootConnected { authorizeCollector() }
        let firstLaunch = settings.consumeFirstLaunch()
        if firstLaunch {
            openMainWindow(page: nil)
        }
    }

    // MARK: Commands

    var isPaused: Bool { engine.core.userPaused }

    func authorizeCollector() {
        guard !settings.authorizingCollector, !collector.isRootConnected else { return }
        settings.authorizingCollector = true
        Task {
            await collector.authorize()
            settings.authorizingCollector = false
            if collector.isRootConnected, engine.isLive { engine.useLiveData() }
        }
    }

    func retryStopped() {
        if engine.isLive && !collector.isRootConnected { authorizeCollector() }
        else { engine.retryStopped() }
    }

    func retrySource(_ source: SourceID) {
        if engine.isLive && !collector.isRootConnected { authorizeCollector() }
        else { engine.retry(source) }
    }

    func togglePause() {
        engine.toggleUserPaused()
    }

    func setProcessListVisible(_ visible: Bool, on page: Page) {
        mainWindow?.setProcessListVisible(visible, on: page)
    }

    func openMainWindow(page: Page?) {
        if let page { settings.selectedPage = page }
        if mainWindow == nil {
            let controller = MainWindowController(app: self, reusing: mainWindowShell)
            mainWindowShell = controller.window
            controller.onClose = { [weak self] in
                self?.mainWindow = nil
                DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
            }
            mainWindow = controller
        }
        setActivationPolicy(.regular)
        mainWindow?.present()
    }

    func openSettings(tab: SettingsTab?) {
        if settingsWindow == nil {
            let controller = SettingsWindowController(app: self)
            controller.onClose = { [weak self] in
                self?.settingsWindow = nil
                DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
            }
            settingsWindow = controller
        }
        setActivationPolicy(.regular)
        settingsWindow?.present(tab: tab)
    }

    func showAbout() {
        setActivationPolicy(.regular)
        NSApp.activate()
        let description = engine.isLive ? "Native performance monitoring for Apple silicon." : "Design preview with simulated data."
        let credits = NSMutableAttributedString(
            string: "\(description)\nGNU General Public License v3.0 only (GPL-3.0-only).\nProvided without warranty. You may redistribute it under this license.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        if let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil) {
            credits.append(NSAttributedString(string: "\nView LICENSE", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: license]))
        }
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    func togglePanel() {
        guard let button = statusItem.button else { return }
        panel.toggle(from: button)
    }

    #if DEBUG
    func openGallery() {
        if gallery == nil {
            let controller = DesignGalleryController(app: self)
            controller.onClose = { [weak self] in
                self?.gallery = nil
                self?.updateActivationPolicy()
            }
            gallery = controller
        }
        setActivationPolicy(.regular)
        gallery?.present()
    }
    #endif

    // MARK: Status item

    func refreshStatusItem() {
        let content = StatusGlyph.content(
            snapshot: engine.snapshot,
            history: engine.history,
            top: settings.menuTopLine,
            bottom: settings.menuBottomLine,
            showsGraph: settings.showsMiniGraph,
            unit: settings.temperatureUnit,
            height: statusItem.height
        )
        statusItem.update(content)
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: isPaused ? "Resume Monitoring" : "Pause Monitoring", key: "p", modifiers: [.command, .shift]) { [weak self] in
            self?.togglePause()
        })
        menu.addItem(ClosureMenuItem(title: "Open Window", key: "o") { [weak self] in self?.openMainWindow(page: nil) })
        menu.addItem(ClosureMenuItem(title: "Settings…", key: ",") { [weak self] in self?.openSettings(tab: nil) })
        #if DEBUG
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Design Gallery", key: "g", modifiers: [.command, .option]) { [weak self] in self?.openGallery() })
        #endif
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "About \(Self.appName)") { [weak self] in self?.showAbout() })
        menu.addItem(ClosureMenuItem(title: "Quit \(Self.appName)", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "PerfMoon"
    }

    // MARK: Settings

    private func updateNetworkDemand() {
        engine.setDemand(.menuNetwork, active: settings.menuTopLine.usesNetwork || settings.menuBottomLine.usesNetwork)
    }

    private func settingsChanged(_ change: AppSettings.Change) {
        switch change {
        case .continuousHistory:
            engine.setDemand(.continuousHistory, active: settings.continuousHistory)
        case .updateInterval:
            engine.setUserInterval(settings.updateInterval)
        case .temperatureSource:
            engine.setTemperatureSource(settings.temperatureSource)
        case .networkInterface:
            engine.setNetworkInterface(settings.networkInterface.isEmpty ? nil : settings.networkInterface)
        case .menuBar:
            updateNetworkDemand()
            refreshStatusItem()
        case .temperatureUnit:
            refreshStatusItem()
        case .page:
            mainWindow?.pageDidChange()
        case .launchAtLogin:
            guard engine.isLive, !changingLoginItem else { return }
            changingLoginItem = true
            defer { changingLoginItem = false }
            do {
                if settings.launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                settings.launchAtLogin = SMAppService.mainApp.status == .enabled
                let alert = NSAlert()
                alert.messageText = "Couldn't update Launch at Login"
                alert.informativeText = "Check Login Items in System Settings, then try again."
                alert.runModal()
            }
        case .timeRange:
            break
        }
    }

    // MARK: Activation policy

    /// The Dock icon appears only while the main window, Settings, or the gallery is open.
    func updateActivationPolicy() {
        var visible = mainWindow != nil || settingsWindow != nil
        #if DEBUG
        visible = visible || gallery != nil
        #endif
        setActivationPolicy(visible ? .regular : .accessory)
    }

    private func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    // MARK: System events

    private func observeSystem() {
        systemObservers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.refreshThermalStatus() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            systemObservers.append(workspace.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.refreshDiskVolumes() }
            })
        }
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.suspend(.sleep) }
        })
        systemObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.resume(.sleep) }
        })
        let distributed = DistributedNotificationCenter.default()
        systemObservers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.suspend(.screenLocked) }
        })
        systemObservers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.resume(.screenLocked) }
        })
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func invoke() { handler() }
}
