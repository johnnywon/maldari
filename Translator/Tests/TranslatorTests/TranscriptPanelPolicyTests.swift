import XCTest
@testable import Translator

/// The transcript panel must not float its live backdrop blur over the Presentation
/// window's full-screen surface. See `TranscriptPanelPolicy` for the mechanism.
final class TranscriptPanelPolicyTests: XCTestCase {

    func test_panelIsVisibleWhenPresentationModeIsOff() {
        XCTAssertTrue(TranscriptPanelPolicy.shouldShowPanel(
            presentationMode: false, userRequested: false))
        // Even a stale "user asked" flag cannot hide the panel in normal operation.
        XCTAssertTrue(TranscriptPanelPolicy.shouldShowPanel(
            presentationMode: false, userRequested: true))
    }

    func test_presentationModeSuppressesThePanel() {
        XCTAssertFalse(TranscriptPanelPolicy.shouldShowPanel(
            presentationMode: true, userRequested: false))
    }

    /// The operator can always overrule it. Someone who wants to watch the scrolling
    /// record while presenting is allowed to pay for it.
    func test_anExplicitAskWinsOverPresentationMode() {
        XCTAssertTrue(TranscriptPanelPolicy.shouldShowPanel(
            presentationMode: true, userRequested: true))
    }
}
