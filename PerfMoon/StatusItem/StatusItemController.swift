import AppKit
import PerfMoonKit

/// One custom-drawn status item. The image is rebuilt only when its text or bar pixels change.
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private var trendItem: NSStatusItem?
    private var content: StatusGlyph.Content?
    /// Number of times the glyph was redrawn. Debug only.
    private(set) var redrawCount = 0

    var onClick: ((NSStatusBarButton) -> Void)?
    var menuProvider: (() -> NSMenu)?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "PerfMoonStatusItem"
        configure(item, label: "PerfMoon")
    }

    private func configure(_ item: NSStatusItem, label: String) {
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(label)
            button.setAccessibilityHelp("Shows the PerfMoon panel")
        }
    }

    var button: NSStatusBarButton? { item.button }

    var currentContent: StatusGlyph.Content? { content }

    var height: CGFloat {
        let thickness = NSStatusBar.system.thickness
        return thickness > 0 ? thickness : 22
    }

    func update(_ newContent: StatusGlyph.Content) {
        guard newContent != content else { return }
        let previous = content
        content = newContent
        if previous?.hasSameValues(as: newContent) != true {
            redrawCount += 1
            item.button?.image = StatusGlyph.image(newContent)
        }
        item.button?.setAccessibilityValue(newContent.spoken)
        if newContent.showsGraph {
            let created = trendItem == nil
            if created {
                let trend = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                trend.autosaveName = "PerfMoonTrendStatusItem"
                configure(trend, label: "PerfMoon CPU trend")
                trendItem = trend
            }
            if created || previous?.hasSameTrend(as: newContent) != true {
                trendItem?.button?.image = StatusGlyph.trendImage(newContent)
            }
            trendItem?.button?.setAccessibilityValue(newContent.paused ? "Monitoring paused" : "Recent CPU usage")
        } else if let trendItem {
            NSStatusBar.system.removeStatusItem(trendItem)
            self.trendItem = nil
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu, let menu = menuProvider?() {
            let selected = sender === trendItem?.button ? (trendItem ?? item) : item
            selected.menu = menu
            sender.performClick(nil)
            selected.menu = nil
        } else {
            onClick?(sender)
        }
    }
}
