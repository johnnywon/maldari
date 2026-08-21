import XCTest
@testable import Translator

/// Where the source cycle goes from each starting point.
///
/// One rule, two callers: the transcript panel's source pill and ⇧⌘I. The pill had this
/// logic inline and untested for as long as it has existed; extracting it is what gives
/// it coverage.
///
/// Deliberately no round-trip test (`f(f(x)) == x` on the two stable sources): it is
/// entailed by the two direct assertions below — it cannot fail while they pass — so it
/// would be reassurance rather than coverage.
final class SourceCycleTests: XCTestCase {

    func test_microphoneCyclesToSystemAudio() {
        XCTAssertEqual(AudioSourceSelection.microphone.nextInSourceCycle, .systemAudio)
    }

    func test_systemAudioCyclesToMicrophone() {
        XCTAssertEqual(AudioSourceSelection.systemAudio.nextInSourceCycle, .microphone)
    }

    /// The non-obvious case. A per-app source is not part of the cycle, so the first
    /// press leaves it for the microphone rather than doing nothing.
    func test_perAppSourceCyclesToMicrophoneFirst() {
        let zoom = AudioSourceSelection.process(pid: 4321, name: "zoom.us")
        XCTAssertEqual(zoom.nextInSourceCycle, .microphone)
        XCTAssertEqual(zoom.nextInSourceCycle.nextInSourceCycle, .systemAudio)
    }

    // MARK: - shortLabel
    //
    // The panel prints this next to the source icon, so the operator can tell at a
    // glance whether Maldari is hearing them or hearing the call. It is separate from
    // `displayName` only because the panel has a width budget the menus do not.

    func test_shortLabelNamesTheTwoStableSources() {
        XCTAssertEqual(AudioSourceSelection.microphone.shortLabel, "Microphone")
        XCTAssertEqual(AudioSourceSelection.systemAudio.shortLabel, "System audio")
    }

    func test_shortLabelPassesThroughAShortAppName() {
        let zoom = AudioSourceSelection.process(pid: 4321, name: "zoom.us")
        XCTAssertEqual(zoom.shortLabel, "zoom.us")
    }

    /// An app is free to have a long name, and the control island is centred between
    /// two fixed side zones — an untruncated label pushes it off centre.
    func test_shortLabelTruncatesALongAppName() {
        let long = AudioSourceSelection.process(
            pid: 99, name: "Microsoft Teams (work or school)")
        XCTAssertTrue(long.shortLabel.hasSuffix("\u{2026}"), long.shortLabel)
        XCTAssertLessThanOrEqual(long.shortLabel.count, 15)
        XCTAssertTrue(long.shortLabel.hasPrefix("Microsoft"), long.shortLabel)
    }

    /// A name exactly at the budget keeps every character — truncation starts past it,
    /// not at it.
    func test_shortLabelKeepsANameExactlyAtTheBudget() {
        let exact = String(repeating: "a", count: 14)
        XCTAssertEqual(AudioSourceSelection.process(pid: 1, name: exact).shortLabel, exact)
    }
}
