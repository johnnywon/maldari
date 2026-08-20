import AppKit
import SwiftUI

/// The guest-facing Presentation Mode window: a real, resizable, full-screen-able
/// window hosting `PresentationView`, normally sent to a second display while
/// the operator keeps the transcript panel on the laptop.
///
/// It is an `NSWindow` and not an `NSPanel` like the rest of the app's surfaces
/// because it has to behave like a document window: take the green button into
/// its own full-screen space, appear in Mission Control, and stay put when the
/// operator switches apps.
final class PresentationWindow: NSWindow {
    private let settings: AppSettings

    /// Fired when the operator closes the window with its own close button.
    ///
    /// Load-bearing: Presentation Mode is driven by `AppSettings.presentationMode`
    /// and the AppDelegate re-creates the window from that flag on a 0.25s poll.
    /// Without this hook, clicking the close button would have the window silently
    /// reappear a quarter second later.
    var onClose: (() -> Void)?

    init(pipeline: PipelineController, settings: AppSettings = .shared) {
        self.settings = settings

        super.init(
            contentRect: Self.frame(displayName: settings.presentationDisplayName),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false)

        title = "Maldari — Presentation"
        // Chrome-free but still titled: the traffic lights stay (the operator
        // needs a way out) while the bar itself disappears into the feed's
        // background. `PresentationView`'s header content is vertically centred
        // in its 68pt, which keeps it clear of the buttons.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        appearance = NSAppearance(named: .darkAqua)
        // The window's own background, not just the SwiftUI content's: during a
        // live resize AppKit fills newly exposed area with this colour, and the
        // default light grey flashes white on every drag frame.
        backgroundColor = NSColor(srgbRed: 0x0C / 255.0, green: 0x0F / 255.0,
                                  blue: 0x12 / 255.0, alpha: 1)
        // `.fullScreenPrimary`, *not* the `.fullScreenAuxiliary` that
        // `SubtitlePanel` uses: an auxiliary window may only join someone else's
        // full-screen space, so the green button would refuse to take this
        // window full screen — which is the entire point of Presentation mode.
        collectionBehavior = [.fullScreenPrimary]
        // Closing the window must not deallocate it: the AppDelegate keeps a
        // reference and re-shows the same instance, which would otherwise be a
        // use-after-free.
        isReleasedWhenClosed = false
        // Below this the two columns stop being readable as columns; the 64pt
        // gutter eats the text and each side wraps every two words.
        minSize = NSSize(width: 720, height: 420)

        contentView = NSHostingView(
            rootView: PresentationView(pipeline: pipeline, settings: settings))
    }

    /// `close()` rather than an `NSWindowDelegate`: the delegate slot belongs to
    /// AppKit's own hosting machinery, and every close path — the traffic-light
    /// button, ⌘W, and the AppDelegate's own teardown — funnels through here.
    /// The AppDelegate clears `onClose` before its own teardown call, so this
    /// only ever reports operator-initiated closes.
    override func close() {
        super.close()
        onClose?()
    }

    /// Re-home on the configured display after a display reconfiguration or a
    /// settings change. No-op when already correct.
    ///
    /// Deliberately weaker than `SubtitlePanel.applyPosition()`, which restores
    /// its full frame: that panel is fixed-size and click-through, this one the
    /// operator can move and resize. Comparing whole frames here would undo
    /// every manual adjustment on the next settings poll, so we only act when
    /// the window is genuinely on the wrong screen — and even then we move it
    /// rather than re-frame it, keeping whatever size the operator chose.
    func applyDisplay() {
        // Moving a window out of its own full-screen space drops it into a
        // half-drawn state that only a relaunch clears.
        guard !styleMask.contains(.fullScreen) else { return }

        let target = Self.targetScreen(displayName: settings.presentationDisplayName)
        // Frame comparison rather than `screen == target`: NSScreen instances
        // are replaced wholesale on reconfiguration, so identity is unreliable
        // exactly when this method matters most.
        if let current = screen, current.frame == target.frame { return }

        // Translate, do not re-frame. `Self.frame(displayName:)` recomputes a
        // centred 80%-of-visibleFrame rect, which throws away the operator's
        // width, height *and* position — so the 0.25s settings poll that lands
        // while the window is briefly on the other screen would snap it back and
        // silently resize it, undoing exactly the manual adjustment the whole-frame
        // comparison above exists to preserve. Being on the wrong display is a
        // fault of the origin alone, so only the origin is corrected.
        let visible = target.visibleFrame
        // `self.frame` spelled out: this type also declares a static
        // `frame(displayName:)`, and the two must not be confused at a glance.
        let existing = self.frame
        guard existing.width <= visible.width, existing.height <= visible.height else {
            // The operator's size cannot fit the target display at all (a 4K
            // window sent to the laptop's built-in panel). The computed frame is
            // then the only rect guaranteed to fit, so losing the size is the
            // lesser evil.
            setFrame(Self.frame(displayName: settings.presentationDisplayName),
                     display: true, animate: false)
            return
        }
        // Keep the window's offset *within* its screen where possible — an
        // operator who parked it top-left finds it top-left on the new display —
        // then clamp so no edge hangs off, which on macOS would leave part of the
        // feed unreadable or under the menu bar.
        let source = screen?.visibleFrame ?? visible
        var origin = NSPoint(x: existing.minX - source.minX + visible.minX,
                             y: existing.minY - source.minY + visible.minY)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - existing.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - existing.height)
        setFrame(NSRect(origin: origin, size: existing.size),
                 display: true, animate: false)
    }

    /// Centred on the target display at ~80% of its usable area — big enough to
    /// read from the far side of the table, small enough that the operator can
    /// still see and grab the window behind it before going full screen.
    ///
    /// The *initial* frame, and `applyDisplay()`'s last resort. It is not used
    /// for ordinary re-homing: it discards any size the operator chose.
    private static func frame(displayName: String) -> NSRect {
        let visible = targetScreen(displayName: displayName).visibleFrame
        let width = max(720, (visible.width * 0.8).rounded())
        let height = max(420, (visible.height * 0.8).rounded())
        return NSRect(
            x: (visible.midX - width / 2).rounded(),
            y: (visible.midY - height / 2).rounded(),
            width: width,
            height: height)
    }

    /// The display the presentation should use: the connected screen matching
    /// `displayName`, else the physically-topmost. Same rule (and the same
    /// unit-tested `DisplayChoice`) as the subtitle overlay; `NSScreen.main` /
    /// `first` only guard the impossible empty-screen case.
    private static func targetScreen(displayName: String) -> NSScreen {
        let screens = NSScreen.screens
        let mapped = screens.map {
            DisplayChoice.Screen(name: $0.localizedName, frame: $0.frame)
        }
        if let idx = DisplayChoice.index(named: displayName, in: mapped) {
            return screens[idx]
        }
        return NSScreen.main ?? screens.first!
    }
}
