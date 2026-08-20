import XCTest
@testable import Translator

/// Contract tests for the LA-2 local-agreement rule.
///
/// Two properties are what the audience actually experiences, so they are
/// asserted directly rather than inferred from the implementation:
///
/// 1. The frontier never retreats. If it did, one disagreeing revision would
///    dump the whole committed tail back to provisional grey and the projected
///    subtitle would visibly thrash.
/// 2. The frontier never points past the end of the current revision. A
///    revision that shortens the sentence must not leave a commit count that
///    would index out of bounds when the view slices `words.prefix(frontier)`.
final class PrefixConsensusTests: XCTestCase {

    /// Space-split rather than `SpeculativeText.tokenize` on purpose: these
    /// tests should fail only when the consensus rule changes, not when the
    /// tokenizer does.
    private func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    // MARK: - commonPrefixLength

    func test_commonPrefixLength_bothEmpty_isZero() {
        XCTAssertEqual(PrefixConsensus.commonPrefixLength([], []), 0)
    }

    func test_commonPrefixLength_emptyAgainstNonEmpty_isZero() {
        XCTAssertEqual(PrefixConsensus.commonPrefixLength([], ["At", "five"]), 0)
        XCTAssertEqual(PrefixConsensus.commonPrefixLength(["At", "five"], []), 0)
    }

    func test_commonPrefixLength_identical_isFullLength() {
        let a = words("At five thousand units")
        XCTAssertEqual(PrefixConsensus.commonPrefixLength(a, a), 4)
    }

    func test_commonPrefixLength_divergentAtFirstWord_isZero() {
        XCTAssertEqual(
            PrefixConsensus.commonPrefixLength(
                words("For five thousand units"),
                words("At five thousand units")),
            0)
    }

    func test_commonPrefixLength_divergentInMiddle_stopsAtDivergence() {
        // Agreement stops at the first mismatch even though later words match
        // again — a shared suffix is not a shared prefix.
        XCTAssertEqual(
            PrefixConsensus.commonPrefixLength(
                words("At five thousand units"),
                words("At five hundred units")),
            2)
    }

    func test_commonPrefixLength_onePrefixOfOther_isShorterLength() {
        let short = words("At five thousand")
        let long = words("At five thousand units")
        XCTAssertEqual(PrefixConsensus.commonPrefixLength(short, long), 3)
        XCTAssertEqual(PrefixConsensus.commonPrefixLength(long, short), 3)
    }

    // MARK: - merge: advancing

    func test_merge_firstRevision_commitsNothing() {
        // Nothing has been agreed with yet, so no word has survived two
        // revisions and none may render as settled.
        let result = PrefixConsensus.merge(
            previous: [], next: words("At five thousand"), frontier: 0)
        XCTAssertEqual(result.frontier, 0)
        XCTAssertTrue(result.corrected.isEmpty)
    }

    func test_merge_extendedAgreement_advancesFrontier() {
        let result = PrefixConsensus.merge(
            previous: words("At five thousand"),
            next: words("At five thousand units"),
            frontier: 0)
        XCTAssertEqual(result.frontier, 3)
        XCTAssertTrue(result.corrected.isEmpty)
    }

    func test_merge_identicalRevision_commitsEverything() {
        let text = words("At five thousand units")
        let result = PrefixConsensus.merge(previous: text, next: text, frontier: 2)
        XCTAssertEqual(result.frontier, 4)
        XCTAssertTrue(result.corrected.isEmpty)
    }

    // MARK: - merge: holding

    func test_merge_contradictedCommittedWord_holdsFrontierAndReportsIndex() {
        // "thousand" was already committed and this revision rewrites it. The
        // frontier is held at 4 rather than dropped to 2, and index 2 is
        // reported so the UI can animate an in-place correction.
        let result = PrefixConsensus.merge(
            previous: words("At five thousand units"),
            next: words("At five hundred units"),
            frontier: 4)
        XCTAssertEqual(result.frontier, 4)
        XCTAssertEqual(result.corrected, [2])
    }

    func test_merge_contradictionReportsOnlyChangedIndices() {
        // Indices 2 and 4 changed; 3 and 5 happen to match again and must not
        // be flagged. "Exactly those indices" is the contract the view relies
        // on to avoid flashing words that did not move.
        let result = PrefixConsensus.merge(
            previous: words("a b c d e f"),
            next: words("a b X d Y f"),
            frontier: 6)
        XCTAssertEqual(result.frontier, 6)
        XCTAssertEqual(result.corrected, [2, 4])
    }

    func test_merge_contradictionBeyondFrontier_isNotACorrection() {
        // Only words inside the old frontier were shown as settled. A rewrite
        // of still-provisional text is business as usual, not a correction.
        let result = PrefixConsensus.merge(
            previous: words("At five thousand units"),
            next: words("At five thousand widgets"),
            frontier: 3)
        XCTAssertEqual(result.frontier, 3)
        XCTAssertTrue(result.corrected.isEmpty)
    }

    // MARK: - merge: a shortening revision must NOT retreat the frontier

    /// Clamping the frontier to the new length was the obvious implementation and
    /// it was wrong: the frontier can only ever fall that way, so one short
    /// revision permanently discarded committed words — the retreat this rule
    /// exists to forbid. Rendering safety comes from `SpeculativeText`'s read
    /// accessors clamping instead, so a frontier temporarily past the end of a
    /// shortened text simply renders everything as committed until it grows back.
    func test_merge_shorteningRevision_holdsTheFrontier() {
        let result = PrefixConsensus.merge(
            previous: words("At five thousand units total"),
            next: words("At five"),
            frontier: 5)
        XCTAssertEqual(result.frontier, 5, "the frontier must not retreat")
    }

    func test_merge_shorteningToEmpty_holdsTheFrontier() {
        let result = PrefixConsensus.merge(
            previous: words("At five thousand"), next: [], frontier: 3)
        XCTAssertEqual(result.frontier, 3, "even an empty revision must not retreat")
        XCTAssertTrue(result.corrected.isEmpty)
    }

    func test_merge_shorteningWithRewrite_reportsOnlySurvivingIndices() {
        // Index 1 is rewritten and still exists after the shortening, so it is
        // reported. Indices 2 and 3 are gone, so there is nothing to correct —
        // the frontier still holds at 4 and the accessors clamp for rendering.
        let result = PrefixConsensus.merge(
            previous: words("a b c d"),
            next: words("a X"),
            frontier: 4)
        XCTAssertEqual(result.frontier, 4)
        XCTAssertEqual(result.corrected, [1])
    }

    /// The property that actually matters, stated directly: merge never returns a
    /// frontier below the one it was given, for any input.
    func test_merge_neverRetreats_acrossAdversarialInputs() {
        let samples: [[String]] = [
            [], words("a"), words("a b"), words("a b c"), words("x y z"),
            words("a b c d e f"), words("네 확인했습니다"), words("a X c"),
        ]
        for previous in samples {
            for next in samples {
                for frontier in 0...max(previous.count, next.count) {
                    let result = PrefixConsensus.merge(
                        previous: previous, next: next, frontier: frontier)
                    XCTAssertGreaterThanOrEqual(
                        result.frontier, frontier,
                        "retreated from \(frontier) to \(result.frontier) "
                        + "for \(previous) -> \(next)")
                }
            }
        }
    }

    // MARK: - end-to-end

    func test_merge_verbFinalKoreanSequence_frontierNeverRetreats() {
        // "5천 대 기준으로는 요청하신 단가를 맞추기 어렵습니다" is verb-final:
        // the negation only arrives at the very end. An honest speculative
        // translation therefore has to rewrite its own tail, and the consensus
        // rule is what keeps the opening clause still while that happens.
        let revisions = [
            "At five thousand",
            "At five thousand units",
            "At five thousand units the unit price you requested",
            "At five thousand units we can't meet the unit price you asked",
        ]
        let expected = [0, 3, 4, 4]

        var previous: [String] = []
        var frontier = 0
        var history = [frontier]

        for (index, revision) in revisions.enumerated() {
            let next = words(revision)
            let result = PrefixConsensus.merge(
                previous: previous, next: next, frontier: frontier)
            XCTAssertEqual(result.frontier, expected[index],
                           "revision \(index) (\(revision))")
            XCTAssertGreaterThanOrEqual(
                result.frontier, frontier,
                "frontier retreated at revision \(index)")
            XCTAssertLessThanOrEqual(
                result.frontier, next.count,
                "frontier ran past the end at revision \(index)")
            frontier = result.frontier
            previous = next
            history.append(frontier)
        }

        XCTAssertEqual(history, [0, 0, 3, 4, 4])
        // The committed prefix is exactly the clause that survived the
        // negation appearing — nothing past "units" was ever shown as settled.
        XCTAssertEqual(previous.prefix(frontier).joined(separator: " "),
                       "At five thousand units")
    }
}
