import Foundation

/// Whether the transcript panel should be on screen.
///
/// Extracted as a pure function so the rule is testable without AppKit — the window
/// code around it is not reachable from a headless test.
///
/// **Why there is a rule at all.** `TranslatorPanel` is `.floating`, `isOpaque = false`,
/// `[.canJoinAllSpaces, .fullScreenAuxiliary]`, and wraps its content in an
/// `NSVisualEffectView` with `.behindWindow` blending. `PresentationWindow` is
/// `.fullScreenPrimary` at normal level. Put together, a 560x620pt live backdrop-blur
/// panel FOLLOWS the operator into the Presentation window's full-screen space and
/// floats on top of it — so every repaint of the caption surface underneath makes the
/// window server re-sample and re-blur the region beneath the panel, tens of times a
/// second, for the whole meeting.
///
/// That is the mechanism that reaches the *system* pointer. An app saturating its own
/// main thread makes its own UI stutter; it does not slow the cursor. Sustained
/// window-server compositing does, and it costs large IOSurface backing stores while it
/// is at it. It is also simply wrong on screen: two caption surfaces stacked on the
/// projector, one of them a duplicate of the other.
enum TranscriptPanelPolicy {

    /// - Parameters:
    ///   - presentationMode: whether the guest-facing window owns the screen.
    ///   - presentationWindowVisible: whether that window is actually on screen. It is
    ///     not, if the operator miniaturized it or hid the app.
    ///   - userRequested: the operator explicitly asked for the panel (menu → Show
    ///     Transcript Window) since the last time Presentation Mode was turned on.
    static func shouldShowPanel(
        presentationMode: Bool,
        presentationWindowVisible: Bool,
        userRequested: Bool
    ) -> Bool {
        guard presentationMode else { return true }
        // The operator's explicit ask always wins. Someone who wants to watch the
        // scrolling record while presenting is allowed to pay for it.
        if userRequested { return true }
        // Suppress ONLY while the window being protected is actually on screen.
        //
        // Without this the app can end up with nothing visible at all: the operator
        // miniaturizes the Presentation window, the branch in `applySettings` that
        // re-shows it deliberately refuses to un-miniaturize (⌘H and minimize used to
        // undo themselves within 250 ms), and the panel stays ordered out because
        // nobody asked for it. That is the same shape as the launch-with-no-windows
        // failure this project already shipped once, and the suppression must not be
        // able to recreate it.
        return !presentationWindowVisible
    }
}
