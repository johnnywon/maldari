import XCTest
@testable import Translator

/// Fixtures are real-shaped meeting Korean/English, because the rules are tuned
/// against eojeol counts: a five-token sentence puts one substitution at 0.20
/// and two at 0.40, which straddles `materialDivergence` and makes the judge
/// boundary testable without magic numbers.
final class TranscriptArbiterTests: XCTestCase {

    // MARK: - Fixtures

    /// "This quarter's revenue exceeded the target." 5 eojeol.
    private let quarterBase = "이번 분기 매출은 목표를 초과했습니다"
    /// One eojeol different from `quarterBase` (초과 → 달성) → divergence 0.20.
    private let quarterOneOff = "이번 분기 매출은 목표를 달성했습니다"
    /// Two eojeol different (매출은 → 매출이, 초과 → 달성) → divergence 0.40.
    private let quarterTwoOff = "이번 분기 매출이 목표를 달성했습니다"
    /// A completely different Korean sentence → divergence 1.0.
    private let meetingKorean = "다음 회의는 금요일 오후로 미루겠습니다"
    private let priceKorean = "5천 대 기준으로는 단가를 맞추기 어렵습니다"

    private func candidate(
        _ engine: STTEngine,
        _ text: String,
        confidence: Double? = nil,
        reported: Language? = nil
    ) -> TranscriptArbiter.Candidate {
        TranscriptArbiter.Candidate(
            engine: engine,
            text: text,
            confidence: confidence,
            reportedLanguage: reported
        )
    }

    // MARK: - Rule 1: empty candidates

    func test_noCandidates_discards() {
        XCTAssertEqual(TranscriptArbiter.decide([]), .discard)
    }

    func test_allEmpty_discards() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, ""),
            candidate(.openai, "   \n "),
        ])
        XCTAssertEqual(decision, .discard)
    }

    func test_whitespaceOnlySingleCandidate_discards() {
        XCTAssertEqual(TranscriptArbiter.decide([candidate(.rtzr, "\t ")]), .discard)
    }

    func test_emptyCandidate_doesNotOutvoteNonEmptyOne() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, ""),
            candidate(.openai, quarterBase, confidence: 0.4),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    // MARK: - Rule 2: single survivor

    func test_singleKoreanCandidate_isPicked() {
        XCTAssertEqual(
            TranscriptArbiter.decide([candidate(.rtzr, priceKorean, confidence: 0.97)]),
            .pick(.rtzr)
        )
    }

    func test_singleEnglishCandidate_isPicked() {
        let decision = TranscriptArbiter.decide([
            candidate(.openai, "we'll sign the MOU on Friday", confidence: 0.61),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    /// Even romanization garbage wins when it is the only transcript there is —
    /// showing the audience something beats showing them nothing.
    func test_singleRomanizationCandidate_isStillPicked() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "레츠 푸시 더 데드라인", confidence: 0.93),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    // MARK: - Rule 3: engines disagree on the language

    /// The classic failure: English audio, RTZR emits confident Hangul
    /// romanization, OpenAI correctly reports English. RTZR has no English
    /// model, so its high confidence is worthless here.
    func test_rtzrHangulVsOpenAIEnglish_picksOpenAI() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "레츠 푸시 더 데드라인", confidence: 0.96),
            candidate(.openai, "let's push the deadline back a week",
                      confidence: 0.55, reported: .en),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    /// Detection works without a reported language too — RTZR never reports
    /// one, and OpenAI sometimes omits it.
    func test_languageDisagreement_withoutReportedLanguage_picksOpenAI() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "레츠 푸시 더 데드라인", confidence: 0.96),
            candidate(.openai, "let's push the deadline back a week"),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    /// The mirror case: RTZR returning Latin letters is off its own home turf,
    /// which is the strongest signal available that it has lost the thread.
    func test_rtzrLatinVsOpenAIKorean_picksOpenAI() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "MOU KPI ROI", confidence: 0.88),
            candidate(.openai, "다음 주 화요일로 미루겠습니다", confidence: 0.42),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    /// A reported language beats the writing system: OpenAI transcribing
    /// Korean audio in romanized Latin still counts as a Korean candidate,
    /// which turns this into a same-language comparison rather than a dispute.
    func test_reportedLanguage_overridesScriptDetection() {
        let romanized = candidate(.openai, "Ne, algesseumnida", reported: .ko)
        XCTAssertEqual(romanized.language, .ko)
        XCTAssertEqual(candidate(.openai, "Ne, algesseumnida").language, .en)
    }

    // MARK: - Rule 4: both heard Korean

    func test_bothKoreanAndAgreeing_prefersRtzrSpecialist() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, quarterBase, confidence: 0.71),
            candidate(.openai, quarterOneOff, confidence: 0.99),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    func test_bothKoreanIdenticalText_prefersRtzr() {
        let decision = TranscriptArbiter.decide([
            candidate(.openai, priceKorean, confidence: 0.95),
            candidate(.rtzr, priceKorean, confidence: 0.10),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    /// Two different sentences: no local rule can say which clause was really
    /// spoken, so this is the one case worth paying the LLM judge for.
    func test_bothKoreanButDifferentSentences_needsJudge() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, priceKorean, confidence: 0.94),
            candidate(.openai, meetingKorean, confidence: 0.90),
        ])
        XCTAssertEqual(decision, .needsJudge(.ko))
    }

    /// RTZR's reputation does not survive a material disagreement even when it
    /// is the more confident engine.
    func test_koreanJudge_ignoresRtzrConfidence() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, meetingKorean, confidence: 0.99),
            candidate(.openai, quarterBase, confidence: 0.31),
        ])
        XCTAssertEqual(decision, .needsJudge(.ko))
    }

    // MARK: - Rule 4 boundary

    func test_justBelowMaterialDivergence_picksRtzr() {
        XCTAssertEqual(
            TranscriptArbiter.divergence(quarterBase, quarterOneOff),
            0.20, accuracy: 0.0001
        )
        XCTAssertLessThan(
            TranscriptArbiter.divergence(quarterBase, quarterOneOff),
            TranscriptArbiter.materialDivergence
        )
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, quarterBase),
            candidate(.openai, quarterOneOff),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    func test_justAboveMaterialDivergence_needsJudge() {
        XCTAssertEqual(
            TranscriptArbiter.divergence(quarterBase, quarterTwoOff),
            0.40, accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            TranscriptArbiter.divergence(quarterBase, quarterTwoOff),
            TranscriptArbiter.materialDivergence
        )
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, quarterBase),
            candidate(.openai, quarterTwoOff),
        ])
        XCTAssertEqual(decision, .needsJudge(.ko))
    }

    /// Guards the two tests above: if the threshold is ever retuned outside
    /// (0.20, 0.40] the fixtures stop straddling it and those tests would pass
    /// or fail for the wrong reason.
    func test_materialDivergence_straddlesTheBoundaryFixtures() {
        XCTAssertGreaterThan(TranscriptArbiter.materialDivergence, 0.20)
        XCTAssertLessThan(TranscriptArbiter.materialDivergence, 0.40)
    }

    /// Cosmetic differences must not buy a judge call: a trailing period and a
    /// capital letter are the same words.
    func test_punctuationAndCaseDifferencesOnly_neverJudge() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, priceKorean + "."),
            candidate(.openai, priceKorean),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    // MARK: - Rule 5: both heard English

    /// RTZR cannot produce English, so there is nothing to arbitrate — the
    /// generalist wins outright, however confident RTZR sounds.
    func test_bothEnglish_picksOpenAIEvenWhenRtzrIsMoreConfident() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "we will sign the mou on friday", confidence: 0.97),
            candidate(.openai, "we'll sign the MOU on Friday",
                      confidence: 0.42, reported: .en),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    /// The same holds for a *material* English disagreement: a judge cannot
    /// conjure an English transcript out of an engine that has no English
    /// model, so escalating would be pure cost.
    func test_bothEnglishAndMateriallyDifferent_stillPicksOpenAI_neverJudge() {
        let a = "budget approval came through"
        let b = "the timeline slipped to august"
        XCTAssertGreaterThan(
            TranscriptArbiter.divergence(a, b),
            TranscriptArbiter.materialDivergence
        )
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, a, confidence: 0.99),
            candidate(.openai, b, confidence: 0.20),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    // MARK: - Rule 6: language undecidable

    func test_undecidableScript_prefersHigherConfidence() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "12 34", confidence: 0.90),
            candidate(.openai, "12 35", confidence: 0.40),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    func test_undecidableScriptWithEqualConfidence_tieBreaksToOpenAI() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "12 34", confidence: 0.50),
            candidate(.openai, "12 35", confidence: 0.50),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    func test_undecidableScriptWithNoConfidence_tieBreaksToOpenAI() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "12 34"),
            candidate(.openai, "12 35"),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    /// Punctuation-only text is not empty (rule 1 leaves it in) but carries no
    /// letters, so it lands in rule 6 rather than manufacturing a language
    /// dispute.
    func test_punctuationOnlyCandidates_useConfidence() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "...", confidence: 0.30),
            candidate(.openai, "?!", confidence: 0.80),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    /// An undecidable transcript cannot dilute a decidable one: the digits-only
    /// candidate is set aside, leaving RTZR alone rather than triggering a
    /// judge call on a divergence of 1.0.
    func test_undecidableCandidate_doesNotDragDecidableOneToJudge() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "네 확인했습니다", confidence: 0.80),
            candidate(.openai, "12 34", confidence: 0.99),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    // MARK: - Missing confidence

    /// Not reporting a confidence must not win arguments: a known 0.10 beats an
    /// unknown, even though 0.10 is a terrible score.
    func test_nilConfidence_losesToAnyKnownValue() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "12 34", confidence: 0.10),
            candidate(.openai, "12 35"),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    /// And the reverse, so the result is confidence-driven rather than an
    /// artifact of the OpenAI tie-break.
    func test_knownConfidence_beatsNilInEitherPosition() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "12 34"),
            candidate(.openai, "12 35", confidence: 0.10),
        ])
        XCTAssertEqual(decision, .pick(.openai))
    }

    /// Zero is a real score and still outranks "did not say".
    func test_zeroConfidence_beatsNilConfidence() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "12 34", confidence: 0.0),
            candidate(.openai, "12 35"),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    // MARK: - Duplicate engines

    /// A replayed engine's later frame reflects more audio, so it wins: the
    /// second RTZR text disagrees materially with OpenAI, which escalates.
    func test_duplicateEngine_lastWins_divergingText() {
        let decision = TranscriptArbiter.decide([
            candidate(.openai, quarterBase, confidence: 0.60),
            candidate(.rtzr, quarterOneOff, confidence: 0.60),
            candidate(.rtzr, meetingKorean, confidence: 0.60),
        ])
        XCTAssertEqual(decision, .needsJudge(.ko))
    }

    /// Same inputs, reversed RTZR order: the agreeing text is now last, so no
    /// judge. Together these two pin down *last* wins rather than *first*.
    func test_duplicateEngine_lastWins_agreeingText() {
        let decision = TranscriptArbiter.decide([
            candidate(.openai, quarterBase, confidence: 0.60),
            candidate(.rtzr, meetingKorean, confidence: 0.60),
            candidate(.rtzr, quarterOneOff, confidence: 0.60),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    /// Empties are dropped before repeats collapse, so a blank trailing frame
    /// cannot erase the same engine's real transcript.
    func test_duplicateEngine_emptyLaterFrameDoesNotEraseEarlierText() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, "네 알겠습니다", confidence: 0.80),
            candidate(.rtzr, "   "),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    func test_duplicateEngine_emptyEarlierFrameIsIgnored() {
        let decision = TranscriptArbiter.decide([
            candidate(.rtzr, ""),
            candidate(.rtzr, "네 알겠습니다", confidence: 0.80),
        ])
        XCTAssertEqual(decision, .pick(.rtzr))
    }

    // MARK: - divergence()

    func test_divergence_identicalTextIsZero() {
        XCTAssertEqual(TranscriptArbiter.divergence(quarterBase, quarterBase), 0)
    }

    func test_divergence_bothEmptyIsZero() {
        XCTAssertEqual(TranscriptArbiter.divergence("", ""), 0)
        XCTAssertEqual(TranscriptArbiter.divergence("   ", "\n\t"), 0)
    }

    func test_divergence_emptyAgainstTextIsOne() {
        XCTAssertEqual(TranscriptArbiter.divergence("", quarterBase), 1)
        XCTAssertEqual(TranscriptArbiter.divergence(quarterBase, "  "), 1)
    }

    func test_divergence_punctuationOnlyAgainstTextIsOne() {
        XCTAssertEqual(TranscriptArbiter.divergence("…?!", quarterBase), 1)
    }

    func test_divergence_completelyDifferentIsOne() {
        XCTAssertEqual(TranscriptArbiter.divergence(quarterBase, meetingKorean), 1)
        XCTAssertEqual(TranscriptArbiter.divergence("네", "아니요"), 1)
    }

    func test_divergence_isTokenLevelNotCharacterLevel() {
        // One of two eojeol differs → exactly one half, regardless of how many
        // characters the two words happen to share.
        XCTAssertEqual(
            TranscriptArbiter.divergence("매출 목표", "매출 계획"),
            0.5, accuracy: 0.0001
        )
        // "매출은" vs "매출이" shares 2 of 3 characters but is a whole eojeol.
        XCTAssertEqual(
            TranscriptArbiter.divergence("매출은 초과", "매출이 초과"),
            0.5, accuracy: 0.0001
        )
    }

    func test_divergence_normalizesByTheLongerSide() {
        // Two eojeol appended to a two-eojeol sentence → 2 edits over 4 tokens.
        XCTAssertEqual(
            TranscriptArbiter.divergence("네 알겠습니다",
                                         "네 알겠습니다 확인해서 회신드리겠습니다"),
            0.5, accuracy: 0.0001
        )
    }

    func test_divergence_ignoresCaseAndEdgePunctuation() {
        XCTAssertEqual(
            TranscriptArbiter.divergence("Okay, we can ship it.",
                                         "okay we can ship it"),
            0
        )
        XCTAssertEqual(TranscriptArbiter.divergence(priceKorean + ".", priceKorean), 0)
    }

    func test_divergence_isSymmetric() {
        XCTAssertEqual(
            TranscriptArbiter.divergence(quarterBase, quarterTwoOff),
            TranscriptArbiter.divergence(quarterTwoOff, quarterBase),
            accuracy: 0.0001
        )
    }

    func test_divergence_staysWithinUnitRange() {
        let samples = ["", "   ", "네", quarterBase, quarterTwoOff, meetingKorean,
                       "we'll sign the MOU on Friday", "12 34", "…"]
        for a in samples {
            for b in samples {
                let value = TranscriptArbiter.divergence(a, b)
                XCTAssertGreaterThanOrEqual(value, 0, "\(a) / \(b)")
                XCTAssertLessThanOrEqual(value, 1, "\(a) / \(b)")
            }
        }
    }

    // MARK: - Candidate adaptation

    func test_candidateFromMessage_carriesEngineAndTrimsText() {
        let message = STTMessage(seq: 7, isFinal: true, text: "  네 확인했습니다  ",
                                 confidence: 0.91, engine: .rtzr)
        let subject = TranscriptArbiter.Candidate(message)
        XCTAssertEqual(subject.engine, .rtzr)
        XCTAssertEqual(subject.text, "네 확인했습니다")
        XCTAssertEqual(subject.confidence, 0.91)
        XCTAssertEqual(subject.language, .ko)
        XCTAssertFalse(subject.isEmpty)
    }

    func test_candidateFromEmptyMessage_isDiscarded() {
        let message = STTMessage(seq: 8, isFinal: false, text: "   ",
                                 engine: .openai, language: .en)
        let subject = TranscriptArbiter.Candidate(message)
        XCTAssertTrue(subject.isEmpty)
        XCTAssertEqual(TranscriptArbiter.decide([subject]), .discard)
    }
}
