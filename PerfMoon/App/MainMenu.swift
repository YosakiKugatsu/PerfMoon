import AppKit
import PerfMoonKit

/// The app menu bar shown while a window is open.
@MainActor
enum MainMenu {
    static func build(app: AppModel) -> NSMenu {
        let main = NSMenu()
        let name = AppModel.appName

        // App menu
        let appMenu = NSMenu(title: name)
        appMenu.addItem(ClosureMenuItem(title: "About \(name)") { [unowned app] in app.showAbout() })
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem(title: "Settings…", key: ",") { [unowned app] in app.openSettings(tab: nil) })
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenuItem(appMenu))

        // Edit menu, for the sensor search field.
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenuItem(edit))

        // View menu
        let view = NSMenu(title: "View")
        let viewDelegate = ViewMenuDelegate(app: app)
        view.delegate = viewDelegate
        objc_setAssociatedObject(view, &ViewMenuDelegate.key, viewDelegate, .OBJC_ASSOCIATION_RETAIN)
        for (index, page) in Page.allCases.enumerated() {
            view.addItem(ClosureMenuItem(title: page.title, key: String(index + 1)) { [unowned app] in
                app.openMainWindow(page: page)
            })
        }
        view.addItem(.separator())
        let range = NSMenuItem(title: "Time Range", action: nil, keyEquivalent: "")
        let rangeMenu = NSMenu(title: "Time Range")
        for option in TimeRange.allCases {
            let item = ClosureMenuItem(title: option.spokenTitle.capitalized) { [unowned app] in app.settings.timeRange = option }
            item.representedObject = option.rawValue
            rangeMenu.addItem(item)
        }
        range.submenu = rangeMenu
        view.addItem(range)
        view.addItem(.separator())
        let pause = ClosureMenuItem(title: "Pause Monitoring", key: "p", modifiers: [.command, .shift]) { [unowned app] in
            app.togglePause()
        }
        pause.identifier = NSUserInterfaceItemIdentifier("pause")
        view.addItem(pause)
        view.addItem(ClosureMenuItem(title: "Show Panel") { [unowned app] in app.togglePanel() })
        view.addItem(.separator())
        let sidebar = NSMenuItem(title: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        view.addItem(sidebar)
        let fullScreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fullScreen)
        main.addItem(submenuItem(view))

        // Window menu
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(.separator())
        window.addItem(ClosureMenuItem(title: "Open Window", key: "o") { [unowned app] in app.openMainWindow(page: nil) })
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = window
        main.addItem(submenuItem(window))

        #if DEBUG
        let debug = NSMenu(title: "Debug")
        debug.addItem(ClosureMenuItem(title: "Design Gallery", key: "g", modifiers: [.command, .option]) { [unowned app] in app.openGallery() })
        debug.addItem(ClosureMenuItem(title: "Use Live Data", key: "l", modifiers: [.command, .option]) { [unowned app] in app.engine.useLiveData() })
        main.addItem(submenuItem(debug))
        #endif

        return main
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Keeps the Pause title and Time Range checkmark current.
@MainActor
private final class ViewMenuDelegate: NSObject, NSMenuDelegate {
    nonisolated(unsafe) static var key = 0
    unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.identifier?.rawValue == "pause" {
                item.title = app.isPaused ? "Resume Monitoring" : "Pause Monitoring"
            }
            if let submenu = item.submenu, item.title == "Time Range" {
                for option in submenu.items {
                    option.state = (option.representedObject as? Int) == app.settings.timeRange.rawValue ? .on : .off
                }
            }
        }
    }
}
