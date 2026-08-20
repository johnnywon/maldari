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
}
