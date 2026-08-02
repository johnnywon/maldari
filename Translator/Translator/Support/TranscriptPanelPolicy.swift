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
    ///   - userRequested: the operator explicitly asked for the panel (menu → Show
    ///     Transcript Window, or reopening the app from the Dock) since the last time
    ///     Presentation Mode was turned on.
    static func shouldShowPanel(presentationMode: Bool, userRequested: Bool) -> Bool {
        guard presentationMode else { return true }
        // The operator's explicit ask always wins. Someone who wants to watch the
        // scrolling record while presenting is allowed to pay for it.
        return userRequested
    }
}
