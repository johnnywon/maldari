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
    private let subtitleDisplayMenu = NSMenu(title: "Subtitle Display")
    private let subtitleItem = NSMenuItem(title: "Subtitle Mode", action: #selector(toggleSubtitles), keyEquivalent: "")
    private let presentationItem = NSMenuItem(
        title: "Presentation Mode", action: #selector(togglePresentation), keyEquivalent: "p")
    private let presentationDisplayMenu = NSMenu(title: "Presentation Display")
    private let captureModeMenu = NSMenu(title: "Capture Mode")
    private var iconTimer: Timer?

    init(pipeline: PipelineController) {
        self.pipeline = pipeline
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        buildMenu()

        statusItem.button?.image = MaldariIcon.menuBar(.default)
        statusItem.button?.image?.accessibilityDescription = "Maldari"
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

        let captureModeItem = NSMenuItem(title: "Capture Mode", action: nil, keyEquivalent: "")
        captureModeMenu.delegate = self
        captureModeItem.submenu = captureModeMenu
        menu.addItem(captureModeItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Transcript", action: #selector(openTranscript), keyEquivalent: "0")
        openItem.target = self
        menu.addItem(openItem)

        let exportItem = NSMenuItem(title: "Export Transcript…", action: #selector(exportTranscript), keyEquivalent: "e")
        exportItem.target = self
        menu.addItem(exportItem)

        subtitleItem.target = self
        menu.addItem(subtitleItem)

        let subtitleDisplayItem = NSMenuItem(title: "Subtitle Display", action: nil, keyEquivalent: "")
        subtitleDisplayMenu.delegate = self
        subtitleDisplayItem.submenu = subtitleDisplayMenu
        menu.addItem(subtitleDisplayItem)

        presentationItem.target = self
        menu.addItem(presentationItem)

        let presentationDisplayItem = NSMenuItem(
            title: "Presentation Display", action: nil, keyEquivalent: "")
        presentationDisplayMenu.delegate = self
        presentationDisplayItem.submenu = presentationDisplayMenu
        menu.addItem(presentationDisplayItem)
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
            // Presentation Mode forces Subtitle Mode off on the next settings
            // poll, so leaving this item enabled made it a control that lies:
            // clicking it produced no overlay, no checkmark and no explanation.
            // PreferencesView already disables its equivalent toggle.
            subtitleItem.isEnabled = !settings.presentationMode
            subtitleItem.toolTip = settings.presentationMode
                ? "Turn Presentation Mode off first — it already shows both languages."
                : nil
            presentationItem.state = settings.presentationMode ? .on : .off
        } else if menu === sourceMenu {
            rebuildSourceMenu()
        } else if menu === subtitleDisplayMenu {
            rebuildDisplayMenu(subtitleDisplayMenu,
                               chosen: settings.subtitleDisplayName,
                               action: #selector(pickSubtitleDisplay(_:)))
        } else if menu === presentationDisplayMenu {
            rebuildDisplayMenu(presentationDisplayMenu,
                               chosen: settings.presentationDisplayName,
                               action: #selector(pickPresentationDisplay(_:)))
        } else if menu === captureModeMenu {
            rebuildCaptureModeMenu()
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
        // In a bidirectional session the source alone no longer describes what is
        // being captured, so name the direction too.
        let scope = settings.captureMode.isBidirectional
            ? "KO↔EN · \(pipeline.audioSource.displayName)"
            : pipeline.audioSource.displayName
        title.append(NSAttributedString(
            string: label + " — " + scope,
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

    /// Shared by the subtitle and presentation display pickers — same rule, same
    /// "remembered but unplugged" handling, two different settings keys.
    private func rebuildDisplayMenu(_ menu: NSMenu, chosen: String, action: Selector) {
        menu.removeAllItems()

        let auto = NSMenuItem(title: "Automatic (topmost)", action: action, keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = chosen.isEmpty ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        let names = NSScreen.screens.map { $0.localizedName }
        for name in names {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = (name == chosen) ? .on : .off
            menu.addItem(item)
        }

        // Remembered-but-disconnected choice stays visible (and checked).
        if !chosen.isEmpty, !names.contains(chosen) {
            let missing = NSMenuItem(title: "\(chosen) (not connected)", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            missing.state = .on
            menu.addItem(missing)
        }
    }

    private func rebuildCaptureModeMenu() {
        captureModeMenu.removeAllItems()
        for mode in CaptureMode.allCases {
            let item = NSMenuItem(title: mode.displayName,
                                  action: #selector(pickCaptureMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == settings.captureMode) ? .on : .off
            // Bidirectional modes are unusable without an OpenAI key — RTZR runs
            // only a Korean model, so there is nothing to transcribe English with.
            // Show them greyed rather than hiding them, so the reason is visible.
            if mode.isBidirectional, !Credentials.hasOpenAI {
                item.isEnabled = false
                item.toolTip = "Needs an OpenAI API key (Settings → API Keys)"
            }
            captureModeMenu.addItem(item)
        }
    }

    @objc private func pickSubtitleDisplay(_ sender: NSMenuItem) {
        settings.subtitleDisplayName = (sender.representedObject as? String) ?? ""
    }

    @objc private func pickPresentationDisplay(_ sender: NSMenuItem) {
        settings.presentationDisplayName = (sender.representedObject as? String) ?? ""
    }

    @objc private func pickCaptureMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        settings.captureModeRaw = raw
    }

    private func refreshIcon() {
        let state: MaldariIcon.MenuBarState
        if case .failed = pipeline.connectionState {
            state = .error
        } else {
            state = pipeline.isListening ? .live : .default
        }
        let image = MaldariIcon.menuBar(state)
        image.accessibilityDescription = "Maldari"
        statusItem.button?.image = image
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

    @objc private func togglePresentation() {
        settings.presentationMode.toggle()
    }
}
