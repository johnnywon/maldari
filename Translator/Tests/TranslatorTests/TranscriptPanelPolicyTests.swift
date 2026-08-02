import XCTest
@testable import Translator

/// The transcript panel must not float its live backdrop blur over the Presentation
/// window's full-screen surface. See `TranscriptPanelPolicy` for the mechanism.
final class TranscriptPanelPolicyTests: XCTestCase {

    func test_panelIsVisibleWhenPresentationModeIsOff() {
        XCTAssertTrue(TranscriptPanelPolicy.shouldShowPanel(
            presentationMode: false, presentationWindowVisible: false, userRequested: false))
        // Even a stale "user asked" flag cannot hide the panel in normal operation.
        XCTAssertTrue(TranscriptPanelPolicy.shouldShowPanel(
            presentationMode: false, presentationWindowVisible: false, userRequested: true))
    }

    func test_presentationModeSuppressesThePanel() {
        XCTAssertFalse(TranscriptPanelPolicy.shouldShowPanel(
            presentationMode: true, presentationWindowVisible: true, userRequested: false))
    }

    /// The operator can always overrule it. Someone who wants to watch the scrolling
    /// record while presenting is allowed to pay for it.
    func test_anExplicitAskWinsOverPresentationMode() {
        XCTAssertTrue(TranscriptPanelPolicy.shouldShowPanel(
            presentationMode: true, presentationWindowVisible: true, userRequested: true))
    }

    /// The failure this policy must never cause: no windows at all.
    ///
    /// The operator miniaturizes the Presentation window while presenting. The branch
    /// in `applySettings` that re-shows it deliberately refuses to un-miniaturize —
    /// minimize and ⌘H used to undo themselves within 250 ms. If the panel stayed
    /// suppressed too, the app would have nothing on screen, which is the same shape
    /// as the launch-with-no-windows bug this project already shipped once.
    func test_panelReturnsWhenThePresentationWindowIsNotActuallyOnScreen() {
        XCTAssertTrue(TranscriptPanelPolicy.shouldShowPanel(
            presentationMode: true, presentationWindowVisible: false, userRequested: false),
            "Presentation Mode is on but its window is miniaturized or hidden — "
            + "suppressing the panel too leaves the app with no windows at all")
    }
}
