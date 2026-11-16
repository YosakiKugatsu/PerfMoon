// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

#if DEBUG
import AppKit
import PerfMoonKit
import SwiftUI

/// Debug-only window for UI review: scenarios, source behaviors, run-state events, and scheduler state.
/// Never compiled into Release builds.
@MainActor
final class DesignGalleryController: NSWindowController, NSWindowDelegate {
    private unowned let app: AppModel
    private let state: GalleryState
    private var observer: Int?
    var onClose: (() -> Void)?

    init(app: AppModel) {
        self.app = app
        state = GalleryState(app: app)
        let hosting = NSHostingController(rootView: DesignGalleryView(state: state, app: app))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Design Gallery"
        window.subtitle = "Debug build only"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 880, height: 680))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        if observer == nil {
            observer = app.engine.addObserver { [weak state] _ in state?.refresh() }
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        if let observer { app.engine.removeObserver(observer) }
        observer = nil
        onClose?()
    }
}

@MainActor
@Observable
final class GalleryState {
    @ObservationIgnored private unowned let app: AppModel
    var scenario: FixtureScenario
    private(set) var sources: [SourceStatus] = []
    private(set) var intervals: [JobID: TimeInterval] = [:]
    private(set) var run = RunState(userPaused: false, systemSuspended: false)
    private(set) var wakeCount = 0
    private(set) var sampleCount = 0
    private(set) var glyphRedraws = 0
    private(set) var log: [String] = []

    init(app: AppModel) {
        self.app = app
        scenario = app.engine.scenario
        refresh()
    }

    func refresh() {
        let engine = app.engine
        sources = engine.core.sourceStatuses()
        intervals = engine.core.intervals
        run = engine.core.run
        wakeCount = engine.wakeCount
        sampleCount = engine.core.sampleCount
        glyphRedraws = app.statusItem.redrawCount
    }

    func apply(_ scenario: FixtureScenario) {
        self.scenario = scenario
        if let source = scenario.temperatureSource {
            app.settings.temperatureSource = source
        } else if case .sensor = app.settings.temperatureSource {
            app.settings.temperatureSource = .cpuMax
        }
        if let interval = scenario.updateInterval {
            app.settings.updateInterval = interval
        }
        app.engine.apply(scenario: scenario)
        note("Applied \(scenario.title)")
        refresh()
    }

    func note(_ message: String) {
        log.insert("\(Format.clockTime(MonitorEngine.now))  \(message)", at: 0)
        if log.count > 12 { log.removeLast() }
    }
}

private struct DesignGalleryView: View {
    @Bindable var state: GalleryState
    let app: AppModel

    @AppStorage("gallery.appearance") private var appearance = "system"
    @AppStorage("gallery.fastBackoff") private var fastBackoff = true

    var body: some View {
        NavigationSplitView {
            List(selection: scenarioBinding) {
                ForEach(FixtureScenario.Group.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(group.scenarios) { scenario in
                            Text(scenario.title).tag(scenario)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.scenario.title).font(.title3.weight(.semibold))
                        Text(state.scenario.summary).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    HStack {
                        Button("Apply Again") { state.apply(state.scenario) }
                        Spacer()
                        Button("Panel") { app.togglePanel() }
                        Button("Window") { app.openMainWindow(page: nil) }
                        Button("Settings") { app.openSettings(tab: nil) }
                    }
                }

                Section("Open Page") {
                    HStack {
                        ForEach(Page.allCases) { page in
                            Button(page.title) { app.openMainWindow(page: page) }
                        }
                    }
                    HStack {
                        ForEach(SettingsTab.allCases) { tab in
                            Button(tab.title) { app.openSettings(tab: tab) }
                        }
                    }
                }

                Section("Run State") {
                    LabeledContent("User paused", value: state.run.userPaused ? "Yes" : "No")
                    LabeledContent("System suspended", value: state.run.systemSuspended ? "Yes" : "No")
                    HStack {
                        Button(state.run.userPaused ? "Resume" : "Pause") {
                            app.togglePause()
                            state.note(state.run.userPaused ? "User resumed" : "User paused")
                        }
                        Button("Simulate Sleep") {
                            app.engine.suspend(.sleep)
                            state.note("System sleep")
                        }
                        Button("Simulate Wake") {
                            app.engine.resume(.sleep)
                            state.note("System wake")
                        }
                        Button("Power Source Changed") {
                            app.engine.recoveryEvent()
                            state.note("Power source changed")
                        }
                    }
                    if !state.log.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(state.log, id: \.self) { Text($0) }
                        }
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Sources") {
                    ForEach(state.sources) { status in
                        SourceControlRow(status: status, app: app, state: state)
                    }
                    Toggle("Fast backoff (×10) for review", isOn: $fastBackoff)
                    Toggle("Tp0X reported", isOn: Binding(
                        get: { !app.fixtures.missingSensors.contains("Tp0X") },
                        set: { app.engine.setSensor("Tp0X", missing: !$0) }
                    ))
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Scheduler") {
                    ForEach(JobID.allCases, id: \.self) { job in
                        LabeledContent(job.rawValue, value: state.intervals[job].map { Format.interval($0) } ?? "off")
                            .font(.system(size: 11).monospaced())
                    }
                    LabeledContent("Run loop wakes", value: "\(state.wakeCount)")
                    LabeledContent("Provider samples", value: "\(state.sampleCount)")
                    LabeledContent("Menu bar redraws", value: "\(state.glyphRedraws)")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { applyReviewOptions() }
        .onChange(of: appearance) { applyReviewOptions() }
        .onChange(of: fastBackoff) { applyReviewOptions() }
    }

    private var scenarioBinding: Binding<FixtureScenario?> {
        Binding(
            get: { state.scenario },
            set: { if let scenario = $0 { state.apply(scenario) } }
        )
    }

    private func applyReviewOptions() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        app.engine.setRecoveryTimeScale(fastBackoff ? 0.1 : 1)
    }
}

private struct SourceControlRow: View {
    let status: SourceStatus
    let app: AppModel
    let state: GalleryState

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(status.id.title)
                Text(phaseText)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Behavior", selection: Binding(
                get: { app.fixtures.behavior(for: status.id) },
                set: { behavior in
                    app.engine.setBehavior(behavior, for: status.id)
                    state.note("\(status.id.title): \(behavior.title)")
                }
            )) {
                ForEach(SimulatedBehavior.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 210)
            Button("Stop") {
                app.engine.forceStopped(status.id)
                state.note("\(status.id.title): forced stopped")
            }
            Button("Retry") {
                app.engine.retry(status.id)
                state.note("\(status.id.title): Retry")
            }
        }
    }

    private var phaseText: String {
        let generation = app.fixtures.generations[status.id] ?? 0
        let open = app.fixtures.openSources.contains(status.id) ? "open" : "closed"
        let phase: String
        switch status.phase {
        case .idle: phase = "idle"
        case .active: phase = "active"
        case .recovering(let made, let next):
            phase = "retrying (\(made) failed, next in \(max(0, Int((next - MonitorEngine.now).rounded()))) s)"
        case .stopped: phase = "stopped"
        case .unavailable(let reason): phase = "unavailable: \(reason.rawValue)"
        }
        return "\(phase) · subscription #\(generation) \(open)"
    }
}

/// Debug launch arguments for automated review, e.g.
/// `-PMScenario heavyLoad -PMOpen window -PMPage cpu -PMAppearance dark`.
@MainActor
enum DebugLaunchOptions {
    /// Returns true when the options chose what to open.
    static func apply(to app: AppModel) -> Bool {
        let defaults = UserDefaults.standard
        if let appearance = defaults.string(forKey: "PMAppearance") {
            UserDefaults.standard.set(appearance, forKey: "gallery.appearance")
            switch appearance {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
        }
        if let raw = defaults.string(forKey: "PMScenario"), let scenario = FixtureScenario(rawValue: raw) {
            if let source = scenario.temperatureSource { app.settings.temperatureSource = source }
            if let interval = scenario.updateInterval { app.settings.updateInterval = interval }
            app.engine.apply(scenario: scenario)
        }
        if let raw = defaults.string(forKey: "PMPage"), let page = Page(rawValue: raw) {
            app.settings.selectedPage = page
        }
        if defaults.bool(forKey: "PMGallery") {
            app.openGallery()
        }
        guard let open = defaults.string(forKey: "PMOpen") else { return defaults.bool(forKey: "PMGallery") }
        switch open {
        case "window":
            app.openMainWindow(page: nil)
        case "settings":
            let tab = defaults.string(forKey: "PMSettingsTab").flatMap(SettingsTab.init(rawValue:))
            app.openSettings(tab: tab)
        case "panel":
            // Wait for the status item to be placed before anchoring the panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated { app.togglePanel() }
            }
        case "none":
            break
        default:
            app.openMainWindow(page: nil)
        }
        return true
    }
}
#endif
