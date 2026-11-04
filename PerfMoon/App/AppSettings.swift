import Foundation
import Observation
import PerfMoonKit

/// User preferences, persisted in UserDefaults. Changes are forwarded through `onChange`.
@MainActor
@Observable
final class AppSettings {
    enum Change {
        case updateInterval
        case temperatureSource
        case menuBar
        case temperatureUnit
        case page
        case timeRange
        case launchAtLogin
    }

    @ObservationIgnored var onChange: ((Change) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hadPreviousLaunch: Bool
    var isLiveData = false

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
            save(selectedPage.rawValue, "selectedPage")
            onChange?(.page)
        }
    }

    var timeRange: TimeRange {
        didSet { save(timeRange.rawValue, "timeRange"); onChange?(.timeRange) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hadPreviousLaunch = defaults.object(forKey: "launchAtLogin") != nil
        updateInterval = UpdateInterval(rawValue: defaults.double(forKey: "updateInterval")) ?? .one
        temperatureUnit = defaults.string(forKey: "temperatureUnit").flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
        temperatureSource = defaults.string(forKey: "temperatureSource").map(TemperatureSource.init(storageValue:)) ?? .cpuMax
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
