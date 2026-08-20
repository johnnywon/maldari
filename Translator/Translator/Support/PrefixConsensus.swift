import Foundation

/// Local-agreement (LA-2) prefix consensus for speculative translation.
///
/// Successive speculative translations of a growing sentence share a prefix. A
/// word is *committed* once two consecutive revisions agree on it, at which
/// point the UI renders it as settled. This is what makes it safe to show a
/// translation before the speaker has finished: the committed region only
/// grows, so the audience never watches settled text rearrange itself.
///
/// The rule earns its keep on verb-final Korean. Translating
/// "5천 대 기준으로는 요청하신 단가를 맞추기 어렵습니다" produces, as the
/// hypothesis grows:
///
///     committed[At five thousand units]  provisional[the unit price you requested]
///     committed[At five thousand units]  provisional[we can't meet the unit price…]
///
/// The frontier correctly refuses to advance past "units" while the negation
/// is still unknown, then lands the whole clause at once.
enum PrefixConsensus {

    struct Result: Equatable {
        /// New commit frontier: how many leading words are now committed.
        let frontier: Int
        /// Indices of words that were already committed and whose text this
        /// revision changed. Rare; the UI marks these rather than swapping
        /// them silently.
        let corrected: Set<Int>
    }

    /// Merge a new revision against the previous one.
    ///
    /// The frontier is monotonic — it is never allowed to retreat. When a
    /// revision contradicts a word that was already committed, the frontier is
    /// *held* and the contradicting indices are reported as corrections.
    /// Retreating instead would drop the entire tail back to provisional grey
    /// on every disagreement, which reads as thrashing; a rare in-place
    /// correction reads as a correction.
    ///
    /// The frontier is NOT clamped to `next.count`. A revision that shortens the
    /// sentence would otherwise drag the frontier down with it — a retreat, which
    /// contradicts the monotonicity this rule exists to provide, and which
    /// permanently discarded committed words because the frontier can only fall
    /// that way. Rendering stays safe because `SpeculativeText` clamps at its read
    /// accessors (`effectiveCommittedCount`), so a frontier temporarily past the
    /// end of a shortened text simply renders everything as committed until the
    /// text grows back.
    static func merge(previous: [String], next: [String], frontier: Int) -> Result {
        let agreement = commonPrefixLength(previous, next)
        var corrected: Set<Int> = []
        if frontier > agreement {
            // Words inside the old frontier that this revision rewrote.
            for index in agreement..<min(frontier, next.count) {
                if index >= previous.count || previous[index] != next[index] {
                    corrected.insert(index)
                }
            }
        }
        return Result(frontier: max(frontier, agreement), corrected: corrected)
    }

    /// Length of the shared leading run of equal elements.
    static func commonPrefixLength(_ a: [String], _ b: [String]) -> Int {
        var i = 0
        let limit = min(a.count, b.count)
        while i < limit, a[i] == b[i] { i += 1 }
        return i
    }
}
