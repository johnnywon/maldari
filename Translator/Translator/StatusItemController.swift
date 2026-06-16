import AppKit
import SwiftUI

/// Menu bar item: start/stop listening, audio source picker (mic / system /
/// per-process), connection status dot, transcript + settings shortcuts.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let pipeline: PipelineController
    private let settings = AppSettings.shared

    var onOpenTranscript: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Start Listening", action: #selector(toggleListening), keyEquivalent: "l")
    private let sourceMenu = NSMenu(title: "Audio Source")
    private let subtitleItem = NSMenuItem(title: "Subtitle Mode", action: #selector(toggleSubtitles), keyEquivalent: "")
    private var iconTimer: Timer?

    init(pipeline: PipelineController) {
        self.pipeline = pipeline
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        buildMenu()

        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Maldari")
        statusItem.menu = menu

        iconTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshIcon() }
        }
    }

    deinit {
        iconTimer?.invalidate()
    }

    private func buildMenu() {
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        toggleItem.target = self
        menu.addItem(toggleItem)

        let sourceItem = NSMenuItem(title: "Audio Source", action: nil, keyEquivalent: "")
        sourceMenu.delegate = self
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Transcript", action: #selector(openTranscript), keyEquivalent: "0")
        openItem.target = self
        menu.addItem(openItem)

        let exportItem = NSMenuItem(title: "Export Transcript…", action: #selector(exportTranscript), keyEquivalent: "e")
        exportItem.target = self
        menu.addItem(exportItem)

        subtitleItem.target = self
        menu.addItem(subtitleItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Maldari",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            statusLine.attributedTitle = statusAttributedTitle()
            toggleItem.title = pipeline.isListening ? "Stop Listening" : "Start Listening"
            subtitleItem.state = settings.subtitleMode ? .on : .off
        } else if menu === sourceMenu {
            rebuildSourceMenu()
        }
    }

    private func statusAttributedTitle() -> NSAttributedString {
        let (dotColor, label): (NSColor, String) = {
            switch pipeline.connectionState {
            case .connected: return (.systemGreen, "Connected")
            case .connecting, .reconnecting: return (.systemYellow, pipeline.connectionState.label)
            case .failed: return (.systemRed, pipeline.connectionState.label)
            case .idle: return (.tertiaryLabelColor, pipeline.isListening ? "Starting…" : "Idle")
            }
        }()
        let title = NSMutableAttributedString(
            string: "● ", attributes: [.foregroundColor: dotColor])
        title.append(NSAttributedString(
            string: label + " — " + pipeline.audioSource.displayName,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                         .font: NSFont.menuFont(ofSize: 12)]))
        return title
    }

    private func rebuildSourceMenu() {
        sourceMenu.removeAllItems()

        let mic = NSMenuItem(title: "Microphone", action: #selector(pickMic), keyEquivalent: "")
        mic.target = self
        mic.state = pipeline.audioSource == .microphone ? .on : .off
        sourceMenu.addItem(mic)

        let system = NSMenuItem(title: "System Audio (All)", action: #selector(pickSystem), keyEquivalent: "")
        system.target = self
        system.state = pipeline.audioSource == .systemAudio ? .on : .off
        sourceMenu.addItem(system)

        let processes = SystemAudioCaptureService.runningAudioProcesses()
        if !processes.isEmpty {
            sourceMenu.addItem(.separator())
            let header = NSMenuItem(title: "Apps Playing Audio", action: nil, keyEquivalent: "")
            header.isEnabled = false
            sourceMenu.addItem(header)
            for process in processes.prefix(12) {
                let item = NSMenuItem(title: process.name, action: #selector(pickProcess(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["pid": NSNumber(value: process.pid), "name": process.name] as NSDictionary
                if case .process(let pid, _) = pipeline.audioSource, pid == process.pid {
                    item.state = .on
                }
                sourceMenu.addItem(item)
            }
        }
    }

    private func refreshIcon() {
        let symbol: String
        if case .failed = pipeline.connectionState {
            symbol = "waveform.badge.exclamationmark"
        } else {
            symbol = pipeline.isListening ? "waveform.circle.fill" : "waveform"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Maldari")
    }

    // MARK: - Actions

    @objc private func toggleListening() { pipeline.toggleListening() }
    @objc private func pickMic() { pipeline.switchSource(.microphone) }
    @objc private func pickSystem() { pipeline.switchSource(.systemAudio) }

    @objc private func pickProcess(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? NSDictionary,
              let pid = (info["pid"] as? NSNumber)?.int32Value,
              let name = info["name"] as? String else { return }
        pipeline.switchSource(.process(pid: pid, name: name))
    }

    @objc private func openTranscript() { onOpenTranscript?() }
    @objc private func exportTranscript() { pipeline.exportTranscript() }
    @objc private func openSettings() { onOpenSettings?() }

    @objc private func toggleSubtitles() {
        settings.subtitleMode.toggle()
    }
}
