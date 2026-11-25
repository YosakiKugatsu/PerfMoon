// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation
import PerfMoonKit

/// User preferences, persisted in UserDefaults. Changes are forwarded through `onChange`.
@MainActor
@Observable
final class AppSettings {
    enum Change {
        case updateInterval
        case continuousHistory
        case temperatureSource
        case networkInterface
        case menuBar
        case temperatureUnit
        case page
        case timeRange
        case launchAtLogin
    }

    @ObservationIgnored var onChange: ((Change) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hadPreviousLaunch: Bool
    @ObservationIgnored private var pageWrite: Task<Void, Never>?
    var showsStatistics = false
    var isLiveData = false
    var collectorConnected = false
    var authorizingCollector = false

    var continuousHistory: Bool {
        didSet {
            guard continuousHistory != oldValue else { return }
            save(continuousHistory, "continuousHistory")
            onChange?(.continuousHistory)
        }
    }

    var updateInterval: UpdateInterval {
        didSet { save(updateInterval.rawValue, "updateInterval"); onChange?(.updateInterval) }
    }

    var temperatureUnit: TemperatureUnit {
        didSet { save(temperatureUnit.rawValue, "temperatureUnit"); onChange?(.temperatureUnit) }
    }

    var temperatureSource: TemperatureSource {
        didSet {
            guard temperatureSource != oldValue else { return }
            save(temperatureSource.storageValue, "temperatureSource")
            onChange?(.temperatureSource)
        }
    }

    /// Empty selects the active physical service, including when a VPN is connected.
    var networkInterface: String {
        didSet {
            guard networkInterface != oldValue else { return }
            save(networkInterface, "networkInterface")
            onChange?(.networkInterface)
        }
    }

    var menuTopLine: MenuBarMetric {
        didSet { save(menuTopLine.rawValue, "menuTopLine"); onChange?(.menuBar) }
    }

    var menuBottomLine: MenuBarMetric {
        didSet { save(menuBottomLine.rawValue, "menuBottomLine"); onChange?(.menuBar) }
    }

    var showsMiniGraph: Bool {
        didSet { save(showsMiniGraph, "showsMiniGraph"); onChange?(.menuBar) }
    }

    /// Mirrored to the native login-item registration by AppModel.
    var launchAtLogin: Bool {
        didSet { save(launchAtLogin, "launchAtLogin"); onChange?(.launchAtLogin) }
    }

    var selectedPage: Page {
        didSet {
            guard selectedPage != oldValue else { return }
            schedulePageWrite()
            onChange?(.page)
        }
    }

    var timeRange: TimeRange {
        didSet { save(timeRange.rawValue, "timeRange"); onChange?(.timeRange) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hadPreviousLaunch = defaults.object(forKey: "launchAtLogin") != nil
        continuousHistory = defaults.object(forKey: "continuousHistory") == nil || defaults.bool(forKey: "continuousHistory")
        updateInterval = UpdateInterval(rawValue: defaults.double(forKey: "updateInterval")) ?? .one
        temperatureUnit = defaults.string(forKey: "temperatureUnit").flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
        temperatureSource = defaults.string(forKey: "temperatureSource").map(TemperatureSource.init(storageValue:)) ?? .cpuMax
        networkInterface = defaults.string(forKey: "networkInterface") ?? ""
        menuTopLine = defaults.string(forKey: "menuTopLine").flatMap(MenuBarMetric.init(rawValue:)) ?? .cpuUsage
        menuBottomLine = defaults.string(forKey: "menuBottomLine").flatMap(MenuBarMetric.init(rawValue:)) ?? .systemPower
        showsMiniGraph = defaults.object(forKey: "showsMiniGraph") as? Bool ?? false
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        selectedPage = defaults.string(forKey: "selectedPage").flatMap(Page.init(rawValue:)) ?? .overview
        timeRange = TimeRange(rawValue: defaults.integer(forKey: "timeRange")) ?? .fiveMinutes
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func schedulePageWrite() {
        pageWrite?.cancel()
        pageWrite = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
            } catch {
                return
            }
            self?.persistSelectedPage()
        }
    }

    func persistSelectedPage() {
        guard pageWrite != nil else { return }
        pageWrite?.cancel()
        pageWrite = nil
        if defaults.string(forKey: "selectedPage") != selectedPage.rawValue {
            save(selectedPage.rawValue, "selectedPage")
        }
    }

    /// Show the window once for a fresh install. Existing configured installations
    /// already had that introduction before this preference was added.
    func consumeFirstLaunch() -> Bool {
        let introduced = defaults.bool(forKey: "hasCompletedFirstLaunch")
            || hadPreviousLaunch
            || defaults.object(forKey: "updateInterval") != nil
            || defaults.object(forKey: "menuTopLine") != nil
            || defaults.object(forKey: "menuBottomLine") != nil
        defaults.set(true, forKey: "hasCompletedFirstLaunch")
        return !introduced
    }
}
