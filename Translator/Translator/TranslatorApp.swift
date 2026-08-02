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
            // Route the standard Settings… item (⌘,) through the AppDelegate
            // so it opens the same window the gear menu does — above the
            // always-on-top panel — instead of the scene window behind it.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showPreferences() }
                    .keyboardShortcut(",", modifiers: .command)
            }
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
                Button("Toggle Presentation Mode") { appDelegate.togglePresentationMode() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
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
    private var presentationWindow: PresentationWindow?
    private var statusItemController: StatusItemController?
    private let settings = AppSettings.shared
    private let pipeline = PipelineController()
    /// Last-seen capture mode and provider, so a Settings change can restart
    /// capture. The settings poll below is the only observation point we have.
    private var lastCaptureMode: CaptureMode = AppSettings.shared.captureMode

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
            // Clicking the Dock icon with nothing on screen means "show me something".
            // While presenting, that something is the Presentation window — latching
            // `panelUserRequested` here instead would defeat the suppression for the
            // rest of the session on a single Dock click, which is not what the
            // operator asked for. Only the explicit menu item sets that flag.
            if settings.presentationMode, let presentation = presentationWindow {
                presentation.makeKeyAndOrderFront(nil)
            } else {
                panel?.orderFront(nil)
            }
        }
        return true
    }

    private func setupPanel() {
        let root = TranscriptView(pipeline: pipeline, settings: settings, onOpenSettings: { [weak self] in
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

    /// The operator explicitly asked for the transcript panel while Presentation Mode
    /// is on. Reset when Presentation Mode is turned on, so the ask is per-session
    /// rather than sticky forever. See `TranscriptPanelPolicy`.
    private var panelUserRequested = false
    /// Last values pushed to the panel, so the 0.25 s poll can skip work that would
    /// change nothing. See `applySettings`.
    private var lastAppliedOpacity: Double?
    private var lastAppliedLevel: NSWindow.Level?

    private func logPanelVisibility(_ shown: Bool) {
        DiagnosticLog.shared.info("app", "transcript_panel_visibility", [
            "shown": shown,
            "presentation": settings.presentationMode,
            "user_requested": panelUserRequested,
        ])
    }

    private func applySettings() {
        guard let panel = panel else { return }

        // Guarded, because this runs four times a second for the entire life of the
        // app. Assigning `backgroundColor` allocates an NSColor and marks a translucent
        // window dirty, and assigning `level` is a round trip to the window server —
        // so unguarded, an idle app repainted a blurred panel 14,400 times an hour to
        // set it to the value it already had. That is main-thread and window-server
        // work competing with caption layout for the whole meeting.
        let opacity = settings.windowOpacity
        if lastAppliedOpacity != opacity {
            lastAppliedOpacity = opacity
            panel.backgroundColor = NSColor(
                red: 10/255, green: 10/255, blue: 18/255, alpha: opacity)
            if let effectView = panel.contentView as? NSVisualEffectView {
                effectView.alphaValue = opacity
            }
        }
        let level: NSWindow.Level = settings.alwaysOnTop ? .floating : .normal
        if lastAppliedLevel != level {
            lastAppliedLevel = level
            panel.level = level
        }

        // Presentation mode and Subtitle mode are mutually exclusive: two caption
        // surfaces on the same screen is noise, and Presentation Mode already
        // shows both languages larger than the overlay ever would. Enabling
        // Presentation Mode wins, and it turns the overlay off in *settings* (not
        // just visually) so the state the user sees in Settings is the truth.
        if settings.presentationMode, settings.subtitleMode {
            settings.subtitleMode = false
        }

        // Subtitle mode panel follows the setting.
        if settings.subtitleMode, subtitlePanel == nil {
            subtitlePanel = SubtitlePanel(pipeline: pipeline)
            subtitlePanel?.orderFront(nil)
        } else if !settings.subtitleMode, let sub = subtitlePanel {
            sub.orderOut(nil)
            subtitlePanel = nil
        }
        // Pick up live position/size changes while the panel is open.
        subtitlePanel?.applyPosition()

        // Presentation window follows its own setting.
        if settings.presentationMode, let existing = presentationWindow {
            // Re-show rather than do nothing. `close()` orders the window out but
            // leaves the object alive (isReleasedWhenClosed is false), so between
            // the close and the next poll there is a window in hand that is not on
            // screen. If the operator hit ⇧⌘P in that gap, presentationMode went
            // back to true while the reference was still non-nil — neither the
            // create nor the destroy branch applied, and Presentation Mode read as
            // ON in Settings and the menu with no window anywhere, permanently.
            // Only revive a window that was *closed*, never one the operator
            // deliberately put away. Re-showing on `!isVisible` alone fought the
            // user: minimizing the window, or Hide Maldari (⌘H), un-did itself
            // within 250ms and the window sprang back onto the projector.
            if !existing.isVisible, !existing.isMiniaturized, !NSApp.isHidden {
                existing.makeKeyAndOrderFront(nil)
            }
        } else if settings.presentationMode {
            let window = PresentationWindow(pipeline: pipeline, settings: settings)
            // Closing the window with its own close button must clear the
            // setting, or the 0.25s poll below immediately reopens it. Clearing
            // our own reference too keeps the branch above from seeing a stale
            // window.
            window.onClose = { [weak self] in
                self?.settings.presentationMode = false
                self?.presentationWindow = nil
            }
            presentationWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if let presentation = presentationWindow {
            presentation.onClose = nil
            presentation.close()
            presentationWindow = nil
        }

        // Keep the blurred, floating transcript panel off the Presentation window's
        // full-screen surface. See `TranscriptPanelPolicy` for why this is a
        // performance fix and not just a tidiness one.
        if !settings.presentationMode { panelUserRequested = false }
        let shouldShow = TranscriptPanelPolicy.shouldShowPanel(
            presentationMode: settings.presentationMode,
            presentationWindowVisible: presentationWindow?.isVisible ?? false,
            userRequested: panelUserRequested)
        // Compared against the window's REAL state, never a remembered one. A memo
        // desynchronises the moment anything else moves the panel — the operator
        // closing it with its red button, or ⌘H — and the poll then either resurrects
        // a window they deliberately put away or refuses to bring back one they want.
        if shouldShow, !panel.isVisible {
            // Only ever *raise* a panel that is merely ordered out. The same
            // distinction the Presentation branch above documents: minimizing, or Hide
            // Maldari, must not undo itself within 250 ms.
            if !panel.isMiniaturized, !NSApp.isHidden {
                panel.orderFront(nil)
                logPanelVisibility(true)
            }
        } else if !shouldShow, panel.isVisible {
            // Ordered out, never closed or released: `applicationShouldHandleReopen`
            // and `showPanelAction` both have to be able to find this object again.
            panel.orderOut(nil)
            logPanelVisibility(false)
        }
        presentationWindow?.applyDisplay()

        // A capture-mode change has to restart capture: the channel layout, the
        // engines, and the sample rates are all decided at start().
        if settings.captureMode != lastCaptureMode {
            DiagnosticLog.shared.info("app", "capture_mode_changed", [
                "mode": settings.captureMode.rawValue,
                "listening": pipeline.isListening,
            ])
            // Only remember the mode once the restart has actually been ACCEPTED.
            // Advancing it unconditionally meant a change made during start()'s
            // async window — when restartIfListening still no-opped — was recorded
            // as handled and never applied, so the session ran on the old mode with
            // Settings and the menu both showing the new one, until the user toggled
            // it twice.
            if pipeline.restartIfListening(force: true) {
                lastCaptureMode = settings.captureMode
            }
        }
    }

    // MARK: - Actions

    private func showPanel() {
        // An explicit ask overrides the Presentation-Mode suppression above.
        panelUserRequested = true
        panel?.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showPanelAction() {
        showPanel()
    }

    @objc func exportTranscript() {
        pipeline.exportTranscript()
    }

    /// Presentation Mode is driven entirely by the setting; the 0.25s poll in
    /// applySettings() creates and tears down the window. Toggling the flag is
    /// the whole action.
    @objc func togglePresentationMode() {
        settings.presentationMode.toggle()
    }

    /// Shows the settings window. We manage an AppKit window directly rather
    /// than poking the SwiftUI Settings scene via the private
    /// `showSettingsWindow:` selector: that selector silently no-ops on recent
    /// macOS, and the scene window would open at normal level *behind* the
    /// always-on-top transcript panel — which reads as "nothing happened".
    @objc func showPreferences() {
        NSApp.activate(ignoringOtherApps: true)

        // One step above the panel's .floating level so it can never open
        // behind it.
        let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

        if let preferencesWindow {
            preferencesWindow.level = level
            preferencesWindow.center()
            preferencesWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Maldari Settings"
        window.contentView = NSHostingView(rootView: PreferencesView(settings: settings))
        window.isReleasedWhenClosed = false
        window.level = level
        // Dark-only settings: darken the whole window chrome (titlebar + tab
        // bar), not just the SwiftUI content.
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.preferencesWindow = window
    }
}
