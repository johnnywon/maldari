import XCTest
@testable import Translator

/// Contract tests for the progressively-revised translation value.
///
/// The interesting behaviour is not the merge itself (that lives in
/// `PrefixConsensusTests`) but the lifecycle guards around it: a stale response
/// must never rewind text the audience has already read, and every terminal
/// path — settle, restart, clear — has to leave the value in a state the row
/// can render without sitting in "translating" forever.
final class SpeculativeTextTests: XCTestCase {

    // MARK: - Fresh value

    func test_fresh_isEmptyAndNotStarted() {
        let text = SpeculativeText()
        XCTAssertTrue(text.isEmpty)
        XCTAssertFalse(text.hasStarted)
        // -1, not 0, so that revision 0 is a genuine first revision rather
        // than indistinguishable from "nothing applied yet".
        XCTAssertEqual(text.revision, -1)
        XCTAssertEqual(text.committedCount, 0)
        XCTAssertTrue(text.committed.isEmpty)
        XCTAssertTrue(text.provisional.isEmpty)
        XCTAssertEqual(text.rendered, "")
        XCTAssertEqual(text.committedText, "")
        XCTAssertEqual(text.provisionalText, "")
        XCTAssertTrue(text.correctedIndices.isEmpty)
    }

    // MARK: - Revision guard

    func test_apply_increasingRevision_isAccepted() {
        var text = SpeculativeText()
        XCTAssertTrue(text.apply(revision: 0, text: "At five thousand"))
        XCTAssertTrue(text.apply(revision: 1, text: "At five thousand units"))
        XCTAssertEqual(text.revision, 1)
        XCTAssertEqual(text.rendered, "At five thousand units")
        XCTAssertTrue(text.hasStarted)
    }

    func test_apply_skippedRevisionNumbers_areAccepted() {
        // The guard is "strictly greater", not "next in sequence": a dropped
        // revision must not wedge the value.
        var text = SpeculativeText()
        XCTAssertTrue(text.apply(revision: 0, text: "one"))
        XCTAssertTrue(text.apply(revision: 7, text: "one two"))
        XCTAssertEqual(text.revision, 7)
    }

    func test_apply_sameRevisionTwice_isRejected() {
        var text = SpeculativeText()
        XCTAssertTrue(text.apply(revision: 3, text: "the agreed price"))
        XCTAssertFalse(text.apply(revision: 3, text: "something else"))
        XCTAssertEqual(text.rendered, "the agreed price")
        XCTAssertEqual(text.revision, 3)
    }

    func test_apply_lowerRevision_isRejected() {
        // The stale-response guard: a slow earlier request landing after a
        // later one must not rewind text the audience has already read.
        var text = SpeculativeText()
        XCTAssertTrue(text.apply(revision: 5, text: "we can't meet that price"))
        XCTAssertFalse(text.apply(revision: 2, text: "we can meet that price"))
        XCTAssertEqual(text.rendered, "we can't meet that price")
        XCTAssertEqual(text.revision, 5)
    }

    func test_apply_leavesStateUntouchedWhenRejected() {
        var text = SpeculativeText()
        text.apply(revision: 0, text: "a b c")
        text.apply(revision: 1, text: "a b c")
        let before = text
        XCTAssertFalse(text.apply(revision: 1, text: "x y z"))
        XCTAssertEqual(text, before)
    }

    func test_apply_afterSettle_isRejected() {
        // Settled text is what gets persisted and uploaded; a late revision
        // arriving after the final pass must not reopen it.
        var text = SpeculativeText()
        text.apply(revision: 0, text: "draft")
        text.settle(text: "final wording")
        XCTAssertFalse(text.apply(revision: 99, text: "late arrival"))
        XCTAssertEqual(text.rendered, "final wording")
        XCTAssertTrue(text.settled)
    }

    // MARK: - Committed / provisional split

    func test_twoRevisions_committedAndProvisionalAgreeWithCount() {
        var text = SpeculativeText()
        text.apply(revision: 0, text: "At five thousand")
        // Nothing has been agreed with yet, so the whole first revision is
        // provisional.
        XCTAssertEqual(text.committedCount, 0)
        XCTAssertEqual(text.committedText, "")
        XCTAssertEqual(text.provisionalText, "At five thousand")

        text.apply(revision: 1, text: "At five thousand units")
        XCTAssertEqual(text.committedCount, 3)
        XCTAssertEqual(Array(text.committed), ["At", "five", "thousand"])
        XCTAssertEqual(Array(text.provisional), ["units"])
        XCTAssertEqual(text.committedText, "At five thousand")
        XCTAssertEqual(text.provisionalText, "units")
        XCTAssertEqual(text.rendered, "At five thousand units")
        // The two halves must reconstruct the whole, in order, or the view
        // would drop or duplicate a word at the seam.
        XCTAssertEqual(text.committed.count + text.provisional.count,
                       text.words.count)
        XCTAssertEqual(
            [text.committedText, text.provisionalText]
                .filter { !$0.isEmpty }.joined(separator: " "),
            text.rendered)
    }

    func test_apply_contradictingCommittedWord_reportsCorrection() {
        var text = SpeculativeText()
        text.apply(revision: 0, text: "a b c")
        text.apply(revision: 1, text: "a b c")
        XCTAssertEqual(text.committedCount, 3)

        text.apply(revision: 2, text: "a b X d")
        // Frontier held, not retreated, and the rewritten index reported so
        // the row animates a correction instead of turning grey again.
        XCTAssertEqual(text.committedCount, 3)
        XCTAssertEqual(text.correctedIndices, [2])
        XCTAssertEqual(text.committedText, "a b X")
        XCTAssertEqual(text.provisionalText, "d")
    }

    func test_apply_cleanRevision_clearsPreviousCorrections() {
        // The view clears `correctedIndices` once rendered, but a revision
        // that corrects nothing must not leave last revision's indices behind
        // and re-flash words that did not move.
        var text = SpeculativeText()
        text.apply(revision: 0, text: "a b c")
        text.apply(revision: 1, text: "a b c")
        text.apply(revision: 2, text: "a b X")
        XCTAssertEqual(text.correctedIndices, [2])
        text.apply(revision: 3, text: "a b X d")
        XCTAssertTrue(text.correctedIndices.isEmpty)
    }

    // MARK: - settle

    func test_settle_commitsEverythingAndMarksSettled() {
        var text = SpeculativeText()
        text.apply(revision: 0, text: "At five thousand")
        text.settle(text: "At five thousand units we can't meet that price")
        XCTAssertTrue(text.settled)
        XCTAssertEqual(text.committedCount, text.words.count)
        XCTAssertEqual(text.committedCount, 9)
        XCTAssertTrue(text.provisional.isEmpty)
        XCTAssertEqual(text.provisionalText, "")
        XCTAssertEqual(text.committedText, text.rendered)
        XCTAssertEqual(text.rendered,
                       "At five thousand units we can't meet that price")
    }

    func test_settle_onFreshValue_marksStarted() {
        // A translation that arrives in one shot still has to read as done,
        // never as "not started".
        var text = SpeculativeText()
        text.settle(text: "Understood.")
        XCTAssertTrue(text.hasStarted)
        XCTAssertTrue(text.settled)
        XCTAssertEqual(text.committedCount, 1)
    }

    func test_settle_contradictingCommittedWord_stillReportsCorrection() {
        var text = SpeculativeText()
        text.apply(revision: 0, text: "we can meet that")
        text.apply(revision: 1, text: "we can meet that")
        XCTAssertEqual(text.committedCount, 4)
        text.settle(text: "we can't meet that")
        XCTAssertEqual(text.correctedIndices, [1])
        XCTAssertEqual(text.committedCount, 4)
        XCTAssertTrue(text.settled)
    }

    // MARK: - restart

    func test_restart_clearsWordsAndUnsettles() {
        var text = SpeculativeText()
        text.apply(revision: 0, text: "a b c")
        text.apply(revision: 1, text: "a b c")
        text.settle(text: "a b c")

        text.restart()
        XCTAssertTrue(text.isEmpty)
        XCTAssertEqual(text.words, [])
        XCTAssertEqual(text.committedCount, 0)
        XCTAssertFalse(text.settled)
        XCTAssertTrue(text.correctedIndices.isEmpty)
        XCTAssertEqual(text.rendered, "")
    }

    func test_restart_keepsRevisionCounter() {
        // Deliberate: restart abandons an attempt whose requests may still be
        // in flight, so the counter must keep climbing or those late responses
        // would be accepted as fresh. Callers retrying a translation therefore
        // have to continue numbering, not restart at 0.
        var text = SpeculativeText()
        text.apply(revision: 0, text: "a")
        text.apply(revision: 1, text: "a b")
        text.restart()
        XCTAssertEqual(text.revision, 1)
        XCTAssertFalse(text.apply(revision: 1, text: "stale in-flight response"))
        XCTAssertTrue(text.isEmpty)
        XCTAssertTrue(text.apply(revision: 2, text: "retried translation"))
        XCTAssertEqual(text.rendered, "retried translation")
    }

    // MARK: - clear

    func test_clear_emptiesTextButLeavesItSettled() {
        // The filler case: the model returned the ∅ sentinel, so the row shows
        // source only. It must still read as finished — a filler utterance
        // that stays "translating" would never resolve.
        var text = SpeculativeText()
        text.apply(revision: 0, text: "∅")
        text.clear()
        XCTAssertTrue(text.isEmpty)
        XCTAssertEqual(text.rendered, "")
        XCTAssertEqual(text.committedCount, 0)
        XCTAssertTrue(text.committed.isEmpty)
        XCTAssertTrue(text.provisional.isEmpty)
        XCTAssertTrue(text.correctedIndices.isEmpty)
        XCTAssertTrue(text.settled)
    }

    func test_clear_thenApply_isRejected() {
        var text = SpeculativeText()
        text.apply(revision: 0, text: "∅")
        text.clear()
        XCTAssertFalse(text.apply(revision: 1, text: "late chunk"))
        XCTAssertTrue(text.isEmpty)
    }

    // MARK: - tokenize

    func test_tokenize_collapsesRunsOfWhitespace() {
        XCTAssertEqual(SpeculativeText.tokenize("At   five     thousand"),
                       ["At", "five", "thousand"])
    }

    func test_tokenize_trimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(SpeculativeText.tokenize("   At five   "),
                       ["At", "five"])
    }

    func test_tokenize_treatsNewlinesAndTabsAsSeparators() {
        // Streamed model output arrives with arbitrary whitespace; a token
        // must never carry a newline into the rendered subtitle.
        XCTAssertEqual(SpeculativeText.tokenize("At\nfive\tthousand\r\nunits"),
                       ["At", "five", "thousand", "units"])
    }

    func test_tokenize_emptyAndWhitespaceOnly_produceNoTokens() {
        XCTAssertEqual(SpeculativeText.tokenize(""), [])
        XCTAssertEqual(SpeculativeText.tokenize("   "), [])
        XCTAssertEqual(SpeculativeText.tokenize("\n\t "), [])
    }

    func test_tokenize_koreanEojeolAreSpaceDelimited() {
        // Korean eojeol are space-delimited, which is why one rule serves both
        // translation directions.
        XCTAssertEqual(
            SpeculativeText.tokenize("5천 대 기준으로는 단가를 맞추기 어렵습니다"),
            ["5천", "대", "기준으로는", "단가를", "맞추기", "어렵습니다"])
    }

    func test_tokenize_keepsPunctuationAttachedToItsWord() {
        // Tokens are consensus units, not linguistic words: splitting off
        // punctuation would make an added period look like a new word and
        // stall the frontier.
        XCTAssertEqual(SpeculativeText.tokenize("Yes, understood."),
                       ["Yes,", "understood."])
    }

    func test_apply_normalizesWhitespaceInRenderedText() {
        var text = SpeculativeText()
        text.apply(revision: 0, text: "  At   five\nthousand  ")
        XCTAssertEqual(text.rendered, "At five thousand")
    }
}

// MARK: - The production interleaving (streaming, THEN a revision)

/// The tests above call `apply` directly. Production never does: the pipeline
/// streams every token into the value with `applyStreaming` and then calls
/// `apply` with the same accumulated string. That interleaving is what made
/// consensus compare each pass against itself — every pass committed 100% of its
/// own guess, LA-2 never gated, and the correction path was unreachable. These
/// exercise the real sequence.
extension SpeculativeTextTests {

    /// Reproduce exactly what `PipelineController.considerSpeculation` does.
    private func runPass(_ text: inout SpeculativeText, revision: Int, answer: String) {
        var collected = ""
        for word in answer.split(separator: " ") {
            collected += (collected.isEmpty ? "" : " ") + word
            text.applyStreaming(text: collected)
        }
        text.apply(revision: revision, text: answer)
    }

    func test_firstPass_commitsNothing_evenAfterStreaming() {
        var text = SpeculativeText()
        runPass(&text, revision: 0, answer: "At five thousand units the unit price you requested")

        XCTAssertEqual(text.committedCount, 0,
                       "one pass has agreed with nothing — it must commit nothing")
        XCTAssertTrue(text.committed.isEmpty)
        XCTAssertEqual(text.provisional.count, 9)
    }

    func test_secondPass_commitsOnlyTheAgreedPrefix() {
        var text = SpeculativeText()
        runPass(&text, revision: 0, answer: "At five thousand units the unit price you requested")
        runPass(&text, revision: 1, answer: "At five thousand units we can't meet the unit price")

        // "At five thousand units" survived both passes; everything after diverged.
        XCTAssertEqual(text.committedCount, 4)
        XCTAssertEqual(text.committedText, "At five thousand units")
        XCTAssertEqual(text.provisionalText, "we can't meet the unit price")
    }

    /// The verb-final Korean case, end to end through the real interleaving: the
    /// frontier must hold at 4 while the tail rewrites itself, then land.
    func test_verbFinalKorean_frontierHoldsThenLands() {
        var text = SpeculativeText()
        var frontiers: [Int] = []

        runPass(&text, revision: 0, answer: "At five thousand")
        frontiers.append(text.committedCount)
        runPass(&text, revision: 1, answer: "At five thousand units")
        frontiers.append(text.committedCount)
        runPass(&text, revision: 2, answer: "At five thousand units the unit price you requested")
        frontiers.append(text.committedCount)
        runPass(&text, revision: 3, answer: "At five thousand units we can't meet the unit price you asked")
        frontiers.append(text.committedCount)

        XCTAssertEqual(frontiers, [0, 3, 4, 4],
                       "the frontier must advance only on agreement and never retreat")
        XCTAssertEqual(zip(frontiers, frontiers.dropFirst()).allSatisfy { $0 <= $1 }, true)

        text.settle(text: "At five thousand units we can't meet the unit price you asked for.")
        XCTAssertTrue(text.settled)
        XCTAssertEqual(text.committedCount, text.words.count)
    }

    /// A revision that rewrites an already-committed word must report it, so the
    /// UI can show the correction instead of swapping silently.
    func test_correctionAfterCommit_isReported() {
        var text = SpeculativeText()
        runPass(&text, revision: 0, answer: "However, the mold cost")
        runPass(&text, revision: 1, answer: "However, the mold cost is billed separately")
        XCTAssertEqual(text.committedCount, 4, "\"However, the mold cost\" agreed twice")

        // The glossary lands: 금형 is "tooling", not "mold".
        runPass(&text, revision: 2, answer: "However, the tooling cost is billed separately")

        XCTAssertTrue(text.correctedIndices.contains(2),
                      "the rewritten committed word must be flagged, got \(text.correctedIndices)")
        XCTAssertEqual(text.committedCount, 4, "the frontier must not retreat on a correction")
    }

    /// While a fresh pass streams in from empty, the committed TEXT must stay on
    /// screen. Keeping only the frontier count made the line shrink to one word
    /// and regrow — the reset the carry-over exists to prevent.
    func test_committedTextSurvivesAFreshStream() {
        var text = SpeculativeText()
        runPass(&text, revision: 0, answer: "At five thousand units the unit price")
        runPass(&text, revision: 1, answer: "At five thousand units we can't meet")
        XCTAssertEqual(text.committedText, "At five thousand units")

        // A new pass begins streaming from nothing.
        text.applyStreaming(text: "At")
        XCTAssertEqual(text.committedText, "At five thousand units",
                       "committed words must not shrink while the tail restreams")
        text.applyStreaming(text: "At five thousand units we")
        XCTAssertEqual(text.committedText, "At five thousand units")
        XCTAssertEqual(text.provisionalText, "we")
    }
}
