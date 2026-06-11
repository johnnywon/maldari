import SwiftUI

@main
struct TranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // The SwiftUI App lifecycle owns NSApp.mainMenu and rebuilds it after
    // applicationDidFinishLaunching, so menus must be declared here via
    // .commands — an AppKit menu installed in the delegate gets clobbered.
    var body: some Scene {
        Settings {
            PreferencesView(settings: AppSettings.shared)
        }
        .commands {
            // Edit menu: without these, ⌘V can't paste API keys into Settings.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x")
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c")
                Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v")
                Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a")
            }
            CommandMenu("Transcript") {
                Button("Show Transcript Window") { appDelegate.showPanelAction() }
                    .keyboardShortcut("0")
                Divider()
                Button("Export Transcript…") { appDelegate.exportTranscript() }
                    .keyboardShortcut("e")
                Divider()
                // Live persistence: every session is recorded to disk as it
                // happens, so a crash or restart never loses the transcript.
                Button("Open Session Recordings") {
                    NSWorkspace.shared.open(SessionRecorder.sessionsRoot)
                }
                Button("Open Diagnostic Logs") {
                    NSWorkspace.shared.open(DiagnosticLog.directory)
                }
            }
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: TranslatorPanel?
    private var preferencesWindow: NSWindow?
    private var subtitlePanel: SubtitlePanel?
    private var statusItemController: StatusItemController?
    private let settings = AppSettings.shared
    private let pipeline = PipelineController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.shared.info("app", "launched", [
            "log_file": DiagnosticLog.shared.fileURL.path,
            "model": ClaudeTranslationService.model,
        ])

        // Register bundle identifier for frameworks that need it
        let bundleInfo = Bundle.main.infoDictionary ?? [:]
        if bundleInfo["CFBundleIdentifier"] == nil {
            UserDefaults.standard.register(defaults: ["CFBundleIdentifier": "com.translator.app"])
        }

        NSApp.setActivationPolicy(.regular)
        AppIcon.setDockIcon()

        pipeline.audioSource = settings.defaultSource

        setupPanel()

        statusItemController = StatusItemController(pipeline: pipeline)
        statusItemController?.onOpenTranscript = { [weak self] in self?.showPanel() }
        statusItemController?.onOpenSettings = { [weak self] in self?.showPreferences() }

        // First launch: open Settings if keys are missing.
        if !Credentials.hasRTZR || !Credentials.hasAnthropic {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showPreferences()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            panel?.orderFront(nil)
        }
        return true
    }

    private func setupPanel() {
        let root = TranscriptView(pipeline: pipeline, onOpenSettings: { [weak self] in
            self?.showPreferences()
        })
        let contentView = NSHostingView(rootView: root)
        contentView.frame = NSRect(x: 0, y: 0, width: Theme.windowWidth, height: 620)

        panel = TranslatorPanel(contentView: contentView)
        panel?.orderFront(nil)

        applySettings()

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.applySettings() }
        }
    }

    private func applySettings() {
        guard let panel = panel else { return }

        let opacity = settings.windowOpacity
        panel.backgroundColor = NSColor(red: 10/255, green: 10/255, blue: 18/255, alpha: opacity)
        if let effectView = panel.contentView as? NSVisualEffectView {
            effectView.alphaValue = opacity
        }
        panel.level = settings.alwaysOnTop ? .floating : .normal

        // Subtitle mode panel follows the setting.
        if settings.subtitleMode, subtitlePanel == nil {
            subtitlePanel = SubtitlePanel(pipeline: pipeline)
            subtitlePanel?.orderFront(nil)
        } else if !settings.subtitleMode, let sub = subtitlePanel {
            sub.orderOut(nil)
            subtitlePanel = nil
        }
    }

    // MARK: - Actions

    private func showPanel() {
        panel?.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showPanelAction() {
        showPanel()
    }

    @objc func exportTranscript() {
        pipeline.exportTranscript()
    }

    /// Opens the SwiftUI Settings scene. Falls back to a hand-rolled window
    /// if the private selector ever stops responding.
    @objc func showPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        if NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) { return }

        if let preferencesWindow = preferencesWindow {
            preferencesWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Maldari Settings"
        window.contentView = NSHostingView(rootView: PreferencesView(settings: settings))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.preferencesWindow = window
    }
}
