import XCTest
@testable import Translator

/// Contract tests for the language enum and the script-ratio detector.
///
/// The detector is tier 1 of the transcript arbiter: it runs on every mutating
/// STT hypothesis, so it must answer with no network and no model. The rule
/// that carries the weight is "only letters count" — digits and punctuation are
/// excluded from the denominator, because a short numeric utterance would
/// otherwise be dragged toward whichever side happened to carry more padding.
final class LanguageTests: XCTestCase {

    // MARK: - Language

    func test_other_swapsAndRoundTrips() {
        XCTAssertEqual(Language.ko.other, .en)
        XCTAssertEqual(Language.en.other, .ko)
        for language in Language.allCases {
            XCTAssertEqual(language.other.other, language)
            XCTAssertNotEqual(language.other, language)
        }
    }

    func test_rawValues_areTheCodesWrittenToDisk() {
        // These strings land in diagnostics, the JSONL session recording, and
        // the cloud payload — renaming a case must not change them silently.
        XCTAssertEqual(Language.ko.rawValue, "ko")
        XCTAssertEqual(Language.en.rawValue, "en")
        XCTAssertEqual(Language(rawValue: "ko"), .ko)
        XCTAssertEqual(Language(rawValue: "en"), .en)
        XCTAssertNil(Language(rawValue: "kor"))
    }

    func test_displayName_isHumanReadable() {
        XCTAssertEqual(Language.ko.displayName, "Korean")
        XCTAssertEqual(Language.en.displayName, "English")
    }

    func test_codable_roundTripsThroughRawValue() throws {
        let encoded = try JSONEncoder().encode([Language.ko, .en])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["ko","en"]"#)
        let decoded = try JSONDecoder().decode([Language].self, from: encoded)
        XCTAssertEqual(decoded, [.ko, .en])
    }

    // MARK: - hangulFraction

    func test_hangulFraction_pureHangul_isOne() throws {
        let fraction = try XCTUnwrap(
            ScriptDetector.hangulFraction("안녕하세요 반갑습니다"))
        XCTAssertEqual(fraction, 1.0, accuracy: 0.0001)
    }

    func test_hangulFraction_pureLatin_isZero() throws {
        let fraction = try XCTUnwrap(
            ScriptDetector.hangulFraction("Thanks for the quick reply"))
        XCTAssertEqual(fraction, 0.0, accuracy: 0.0001)
    }

    func test_hangulFraction_evenMix_isOneHalf() throws {
        // Two Hangul syllables, two Latin letters.
        let fraction = try XCTUnwrap(ScriptDetector.hangulFraction("가나 ab"))
        XCTAssertEqual(fraction, 0.5, accuracy: 0.0001)
    }

    func test_hangulFraction_digitsAndPunctuationOnly_isNil() {
        XCTAssertNil(ScriptDetector.hangulFraction("12:30"))
        XCTAssertNil(ScriptDetector.hangulFraction("1,500"))
        XCTAssertNil(ScriptDetector.hangulFraction("...?!"))
        XCTAssertNil(ScriptDetector.hangulFraction("   "))
    }

    func test_hangulFraction_emptyString_isNil() {
        XCTAssertNil(ScriptDetector.hangulFraction(""))
    }

    func test_hangulFraction_excludesDigitsAndPunctuationFromDenominator() throws {
        // "네 100%" is one Hangul letter plus padding. If digits or the percent
        // sign counted, a plain Korean "yes, 100%" would look half-English and
        // the arbiter would think the wrong engine was listening.
        let fraction = try XCTUnwrap(ScriptDetector.hangulFraction("네 100%"))
        XCTAssertEqual(fraction, 1.0, accuracy: 0.0001)
    }

    func test_hangulFraction_numbersDoNotDilutePureLatin() throws {
        let fraction = try XCTUnwrap(ScriptDetector.hangulFraction("Q4 is 1,500"))
        XCTAssertEqual(fraction, 0.0, accuracy: 0.0001)
    }

    // MARK: - Script coverage

    func test_hangulFraction_compatibilityJamoCountsAsHangul() throws {
        // U+3131 ㄱ — STT hypotheses can surface a bare jamo mid-syllable, and
        // it has to read as Korean rather than as "no letters at all".
        let fraction = try XCTUnwrap(ScriptDetector.hangulFraction("\u{3131}"))
        XCTAssertEqual(fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(ScriptDetector.language(of: "\u{3131}"), .ko)
    }

    func test_hangulFraction_conjoiningJamoCountsAsHangul() throws {
        // U+1100 ᄀ, the conjoining (non-compatibility) initial.
        let fraction = try XCTUnwrap(ScriptDetector.hangulFraction("\u{1100}"))
        XCTAssertEqual(fraction, 1.0, accuracy: 0.0001)
    }

    func test_hangulFraction_accentedLatinCountsAsLatin() throws {
        // Not "neither": an accented letter must land in the denominator as
        // Latin, otherwise a loanword-heavy English line would look undecidable.
        let cafe = try XCTUnwrap(ScriptDetector.hangulFraction("café"))
        XCTAssertEqual(cafe, 0.0, accuracy: 0.0001)
        let naive = try XCTUnwrap(ScriptDetector.hangulFraction("naïve"))
        XCTAssertEqual(naive, 0.0, accuracy: 0.0001)

        // U+00E9 é alone: nil here would mean the scalar was ignored entirely.
        let accented = try XCTUnwrap(ScriptDetector.hangulFraction("\u{00E9}"))
        XCTAssertEqual(accented, 0.0, accuracy: 0.0001)

        // And it dilutes a Hangul letter exactly as an ASCII letter would.
        let mixed = try XCTUnwrap(ScriptDetector.hangulFraction("가 \u{00E9}"))
        XCTAssertEqual(mixed, 0.5, accuracy: 0.0001)
    }

    // MARK: - language(of:)

    func test_language_koreanBusinessSentences_areKorean() {
        let sentences = [
            "5천 대 기준으로는 요청하신 단가를 맞추기 어렵습니다",
            "다음 주 월요일까지 견적서를 보내드리겠습니다",
            "계약 조건은 내부 검토 후에 다시 말씀드릴게요",
            "네, 그렇게 진행하겠습니다",
        ]
        for sentence in sentences {
            XCTAssertEqual(ScriptDetector.language(of: sentence), .ko, sentence)
        }
    }

    func test_language_englishBusinessSentences_areEnglish() {
        let sentences = [
            "At five thousand units we can't meet the price you asked for",
            "I'll send over the revised quote by Monday",
            "Let's park that and come back to it after the review",
            "Yes, 100% agreed",
        ]
        for sentence in sentences {
            XCTAssertEqual(ScriptDetector.language(of: sentence), .en, sentence)
        }
    }

    func test_language_noLetters_isNil() {
        XCTAssertNil(ScriptDetector.language(of: "12:30"))
        XCTAssertNil(ScriptDetector.language(of: ""))
        XCTAssertNil(ScriptDetector.language(of: "—"))
    }

    func test_language_defaultThresholdIsInclusiveAtOneHalf() {
        // An exact tie resolves to Korean: `rtzr` is the default engine, so the
        // tie-break should not hand a 50/50 line to the English path.
        XCTAssertEqual(ScriptDetector.language(of: "가나 ab"), .ko)
    }

    // MARK: - threshold parameter

    func test_language_customThreshold_justAboveAndJustBelow() {
        // Four Hangul syllables and one Latin letter: fraction 0.8.
        let text = "가나다라x"
        XCTAssertEqual(ScriptDetector.language(of: text, threshold: 0.75), .ko)
        XCTAssertEqual(ScriptDetector.language(of: text, threshold: 0.85), .en)
        // The comparison is >=, so a threshold exactly at the fraction is Korean.
        XCTAssertEqual(ScriptDetector.language(of: text, threshold: 0.8), .ko)
    }

    func test_language_thresholdDoesNotRescueALetterlessString() {
        // No letters means undecidable at any threshold, including 0.
        XCTAssertNil(ScriptDetector.language(of: "1,500", threshold: 0))
        XCTAssertNil(ScriptDetector.language(of: "1,500", threshold: 1))
    }
}
