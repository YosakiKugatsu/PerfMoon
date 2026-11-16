// SPDX-FileCopyrightText: 2026 YosakiKugatsu
// SPDX-License-Identifier: GPL-3.0-only

import PerfMoonKit
import SwiftUI

struct PanelActions {
    var togglePause: () -> Void
    var openWindow: (Page?) -> Void
    var openSettings: () -> Void
    var retryStopped: () -> Void
    var useCPUMax: () -> Void
    /// Expanding the Memory card requests the process list; collapsing releases it.
    var setProcessListVisible: (Bool) -> Void
    var close: () -> Void
}

/// A fixed-width panel whose native popover follows the content's intrinsic height.
struct PanelView: View {
    let model: DashboardModel
    let machine: MachineInfo
    let actions: PanelActions

    static let width: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(machine: machine, paused: model.run.userPaused, actions: actions)

            VStack(spacing: 8) {
                if let prompt = model.prompt {
                    PromptRow(prompt: prompt, actions: actions)
                }
                CPUPanelSection(model: model)
                GPUPanelSection(model: model)
                MemoryPanelSection(model: model, onProcessListVisibilityChange: actions.setProcessListVisible)
                DiskPanelSection(model: model)
                PowerPanelSection(model: model)
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.monitorPaused, model.run.userPaused)
        .onExitCommand(perform: actions.close)
        .background {
            // Keyboard shortcuts for pages; the window opens on the chosen page.
            PageShortcuts(open: actions.openWindow)
        }
    }
}

private struct PageShortcuts: View {
    let open: (Page?) -> Void

    var body: some View {
        ZStack {
            ForEach(Page.allCases) { page in
                Button(page.title) { open(page) }
                    .keyboardShortcut(KeyEquivalent(page.shortcutKey), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Header

private struct PanelHeader: View {
    let machine: MachineInfo
    let paused: Bool
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(" \(machine.shortChipName)")
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityLabel(machine.chipName)
                if paused {
                    Label("Paused", systemImage: "pause.fill")
                        .labelStyle(PausedLabelStyle())
                } else {
                    Text(hardwareSummary)
                        .font(.pmCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    HeaderButton(
                        symbol: paused ? "play.fill" : "pause.fill",
                        label: paused ? "Resume Monitoring" : "Pause Monitoring",
                        shortcut: "⇧⌘P",
                        action: actions.togglePause
                    )
                    .keyboardShortcut("p", modifiers: [.command, .shift])

                    HeaderButton(symbol: "macwindow", label: "Open Window", shortcut: "⌘O") {
                        actions.openWindow(nil)
                    }
                    .keyboardShortcut("o", modifiers: .command)

                    HeaderButton(symbol: "gearshape", label: "Settings", shortcut: "⌘,", action: actions.openSettings)
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var hardwareSummary: String {
        var items: [String] = []
        if machine.cpuTopology.logicalCPUCount > 0 {
            items.append("\(machine.cpuTopology.logicalCPUCount)-Core CPU")
        }
        if machine.gpuCoreCount > 0 {
            items.append("\(machine.gpuCoreCount)-Core GPU")
        }
        items.append(Format.wholeGigabytes(machine.physicalMemory))
        return items.joined(separator: " · ")
    }
}

private struct PausedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 8, weight: .bold))
            configuration.title
        }
        .font(.pmCaption.weight(.medium))
        .foregroundStyle(.orange)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let label: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help("\(label) (\(shortcut))")
        .accessibilityLabel(label)
    }
}

// MARK: - Prompt

private struct PromptRow: View {
    let prompt: PanelPrompt
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(buttonTitle, action: buttonAction)
                .controlSize(.small)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        switch prompt {
        case .retry: "Some readings are unavailable."
        case .useCPUMax(let id): "\(id) is unavailable."
        }
    }

    private var buttonTitle: String {
        switch prompt {
        case .retry: "Retry"
        case .useCPUMax: "Use CPU Max"
        }
    }

    private func buttonAction() {
        switch prompt {
        case .retry: actions.retryStopped()
        case .useCPUMax: actions.useCPUMax()
        }
    }
}
