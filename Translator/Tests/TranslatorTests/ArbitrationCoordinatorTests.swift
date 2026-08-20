import XCTest
@testable import Translator

/// Reconciliation between the two STT engines, driven with injected timestamps so
/// the timing cases are deterministic rather than flaky.
@MainActor
final class ArbitrationCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> (ArbitrationCoordinator, Box) {
        let box = Box()
        let coordinator = ArbitrationCoordinator(judge: NoopTranscriptJudge())
        coordinator.onResolved = { box.resolved.append($0) }
        coordinator.onCorrected = { box.corrected.append(($0, $1, $2)) }
        return (coordinator, box)
    }

    private final class Box {
        var resolved: [STTMessage] = []
        var corrected: [(Int, String, Language)] = []
    }

    private func final(
        _ seq: Int, _ text: String, engine: STTEngine, language: Language? = nil,
        confidence: Double? = 0.95
    ) -> STTMessage {
        STTMessage(seq: seq, duration: 900, isFinal: true, text: text,
                   confidence: confidence, engine: engine, language: language)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The long-utterance case

    /// RTZR runs `max_utter_duration=5`, so continuous speech gives it a forced
    /// final every 5 seconds; OpenAI's server VAD has no maximum turn length and
    /// can run as long as the speaker does. A match window shorter than RTZR's cap
    /// pruned every challenger but the last, leaving a ~2-second fragment to
    /// compete against a 12-second segment — divergence went to ~0.8, the arbiter
    /// escalated, and the cheap pick (which prefers the Korean specialist)
    /// published the fragment as the entire utterance. Ten of twelve seconds
    /// vanished from the screen, the export and the cloud.
    func test_challengerFinalsSpanningRTZRsForcedSegments_areAllMatched() {
        let (coordinator, box) = makeCoordinator()

        // RTZR forced finals at +5.1 and +10.1, natural final at +12.4.
        coordinator.ingestChallenger(
            final(0, "먼저 초기 발주 수량에 대해", engine: .rtzr),
            at: t0.addingTimeInterval(5.1))
        coordinator.ingestChallenger(
            final(1, "말씀드리자면 5천 대 기준으로는", engine: .rtzr),
            at: t0.addingTimeInterval(10.1))
        coordinator.ingestChallenger(
            final(2, "단가를 맞추기 어렵습니다", engine: .rtzr),
            at: t0.addingTimeInterval(12.4))

        // OpenAI's single final for the same 12 seconds.
        let whole = "먼저 초기 발주 수량에 대해 말씀드리자면 5천 대 기준으로는 단가를 맞추기 어렵습니다"
        coordinator.ingestSegmenter(
            final(10, whole, engine: .openai, language: .ko),
            at: t0.addingTimeInterval(12.6))

        XCTAssertEqual(box.resolved.count, 1)
        let text = try? XCTUnwrap(box.resolved.first?.bestText)
        // The concatenated challenger matches the segmenter, so the specialist
        // wins on agreement — and crucially the WHOLE utterance survives.
        XCTAssertEqual(text, whole,
                       "a fragment must never replace the full utterance")
    }

    /// Matching is bounded by the segment boundary, never by a clock. Any fixed
    /// window truncates a long enough utterance, because OpenAI has no maximum
    /// turn length — so the staleness bound must be far larger than any plausible
    /// sentence, and exists only to stop the buffer growing if the segmenter dies.
    func test_stalenessBoundIsAMemoryGuardNotAMatchingRule() {
        XCTAssertGreaterThan(
            ArbitrationCoordinator.staleAfter, 20,
            "a small staleness bound would prune the start of long utterances, "
            + "which is exactly the bug the boundary rule replaced")
        XCTAssertLessThan(
            ArbitrationCoordinator.lateChallengerGrace, 1.0,
            "the late-challenger grace must be short enough that a genuinely new "
            + "sentence is not mistaken for a straggler")
    }

    // MARK: - The bleed-forward case

    /// The engines race and either can win. A challenger that lands *after* its
    /// own segmenter final used to stay buffered and be matched against the NEXT
    /// segmenter final — so the next utterance was arbitrated against the previous
    /// utterance's transcript and, because divergence was then ~1.0, the cheap
    /// pick published the previous sentence in place of the one just spoken.
    /// One line lost, another duplicated.
    func test_challengerArrivingAfterItsOwnSegmenterFinal_doesNotBleedIntoTheNext() {
        let (coordinator, box) = makeCoordinator()

        // Utterance N: segmenter first, challenger 250ms later.
        coordinator.ingestSegmenter(
            final(10, "네 확인했습니다", engine: .openai, language: .ko),
            at: t0.addingTimeInterval(10.0))
        coordinator.ingestChallenger(
            final(0, "네 확인했습니다", engine: .rtzr),
            at: t0.addingTimeInterval(10.25))

        // Utterance N+1, a different sentence, 1.35s after that challenger —
        // inside the match window, but belonging to the previous segment.
        coordinator.ingestSegmenter(
            final(11, "금요일까지 보내드리겠습니다", engine: .openai, language: .ko),
            at: t0.addingTimeInterval(11.6))

        XCTAssertEqual(box.resolved.count, 2)
        XCTAssertEqual(box.resolved[0].bestText, "네 확인했습니다")
        XCTAssertEqual(box.resolved[1].bestText, "금요일까지 보내드리겠습니다",
                       "the second utterance must not carry the first's transcript")
    }

    /// An empty segmenter final still closes a segment. Returning early without
    /// clearing the buffer left that segment's challengers to bleed into the next
    /// utterance — the same failure by another route.
    func test_emptySegmenterFinal_clearsTheChallengerBuffer() {
        let (coordinator, box) = makeCoordinator()

        coordinator.ingestChallenger(
            final(0, "어 그", engine: .rtzr), at: t0.addingTimeInterval(1.0))
        // Empty final: bestText is nil, so this is the "clears the hypothesis"
        // path.
        coordinator.ingestSegmenter(
            STTMessage(seq: 10, isFinal: true, text: "   ", engine: .openai),
            at: t0.addingTimeInterval(1.2))
        coordinator.ingestSegmenter(
            final(11, "다음 안건으로 넘어가겠습니다", engine: .openai, language: .ko),
            at: t0.addingTimeInterval(2.0))

        let last = box.resolved.last
        XCTAssertEqual(last?.bestText, "다음 안건으로 넘어가겠습니다",
                       "a discarded segment's challenger must not reach the next one")
    }

    // MARK: - Basic routing

    /// A lone segmenter final with no challenger resolves to itself, unchanged.
    func test_segmenterWithNoChallenger_passesThrough() {
        let (coordinator, box) = makeCoordinator()
        coordinator.ingestSegmenter(
            final(10, "Could you send that breakdown?", engine: .openai, language: .en),
            at: t0)
        XCTAssertEqual(box.resolved.count, 1)
        XCTAssertEqual(box.resolved.first?.bestText, "Could you send that breakdown?")
        XCTAssertEqual(box.resolved.first?.language, .en)
    }

    /// Partials pass straight through — the hypothesis line belongs to the
    /// segmenter alone, so it must never be delayed by arbitration.
    func test_segmenterPartials_passThroughImmediately() {
        let (coordinator, box) = makeCoordinator()
        coordinator.ingestSegmenter(
            STTMessage(seq: 10, isFinal: false, text: "먼저 초기", engine: .openai), at: t0)
        XCTAssertEqual(box.resolved.count, 1)
        XCTAssertFalse(box.resolved[0].isFinal)
    }

    /// Challenger partials are dropped: alternating two engines' guesses on one
    /// line would make it flip-flop mid-word.
    func test_challengerPartials_areIgnored() {
        let (coordinator, box) = makeCoordinator()
        coordinator.ingestChallenger(
            STTMessage(seq: 0, isFinal: false, text: "먼저", engine: .rtzr), at: t0)
        XCTAssertTrue(box.resolved.isEmpty)
    }

    /// English speech: the specialist produces Hangul approximating the sounds,
    /// the generalist produces English. The generalist must win, and the resolved
    /// language must be English so the row translates EN→KO.
    func test_englishSpeech_resolvesToTheGeneralistAndEnglish() {
        let (coordinator, box) = makeCoordinator()
        coordinator.ingestChallenger(
            final(0, "쿠쥬 센드 댓 브레이크다운", engine: .rtzr), at: t0)
        coordinator.ingestSegmenter(
            final(10, "Could you send that breakdown?", engine: .openai, language: .en),
            at: t0.addingTimeInterval(0.3))

        XCTAssertEqual(box.resolved.count, 1)
        XCTAssertEqual(box.resolved[0].bestText, "Could you send that breakdown?")
        XCTAssertEqual(box.resolved[0].language, .en)
        XCTAssertEqual(box.resolved[0].engine, .openai)
    }

    /// reset() must clear the segment boundary too, or the first utterance of a
    /// new session is measured against the last one of the previous session.
    func test_reset_clearsTheSegmentBoundary() {
        let (coordinator, box) = makeCoordinator()
        coordinator.ingestSegmenter(final(10, "이전 세션", engine: .openai, language: .ko), at: t0)
        coordinator.reset()
        coordinator.ingestChallenger(
            final(0, "새 세션입니다", engine: .rtzr), at: t0.addingTimeInterval(0.1))
        coordinator.ingestSegmenter(
            final(11, "새 세션입니다", engine: .openai, language: .ko),
            at: t0.addingTimeInterval(0.2))
        XCTAssertEqual(box.resolved.last?.bestText, "새 세션입니다",
                       "a challenger from after reset must still be matchable")
    }
}
