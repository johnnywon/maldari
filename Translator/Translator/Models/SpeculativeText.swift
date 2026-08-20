import Foundation

/// A translation being progressively revised while the speaker is still talking.
///
/// Words up to `committedCount` have survived agreement between two consecutive
/// speculative revisions (see `PrefixConsensus`) and render as settled; the rest
/// is the provisional tail. `committedCount` is monotonic within an utterance:
/// text shown as settled never reverts to provisional.
struct SpeculativeText: Equatable, Sendable {
    /// The render buffer: what is on screen right now, including the tail being
    /// streamed.
    private(set) var words: [String] = []

    /// The word array as of the last COMPLETED revision — the baseline consensus
    /// compares a new revision against.
    ///
    /// Load-bearing, and its absence was the worst bug in this feature. The
    /// pipeline streams every token into `words` and then calls
    /// `apply(revision:text:)` with the same accumulated string, so merging
    /// against `words` compared each pass **against itself**: agreement was always
    /// total, the frontier jumped to the full length, and every pass committed
    /// 100% of its own guess. LA-2 never gated anything, `correctedIndices` was
    /// always empty so the correction animation was unreachable, and a translation
    /// of half a sentence was presented to the room in settled colour as final —
    /// then silently rewritten. The unit tests missed it because they call
    /// `apply` directly without interleaving `applyStreaming` first, which is the
    /// only reason `words` still held the previous revision there.
    private(set) var revisionWords: [String] = []

    /// Number of leading words that are committed. Monotonic within an utterance.
    ///
    /// May temporarily EXCEED `words.count`. That is deliberate: when the final
    /// translation pass streams in from empty, `words` momentarily holds one or
    /// two tokens while the frontier still refers to words committed during the
    /// hypothesis. Clamping the stored value here (rather than at the accessors)
    /// ratcheted the frontier down to the length of the partial stream, and since
    /// it can only decrease that way it collapsed to zero and never recovered —
    /// destroying every carried commitment and making the translation visibly
    /// reset to grey the instant the speaker stopped talking. Read through
    /// `effectiveCommittedCount` / `committed` / `provisional`, which clamp.
    private(set) var committedCount: Int = 0

    /// `committedCount` clamped to what is actually renderable right now.
    var effectiveCommittedCount: Int { min(committedCount, words.count) }

    /// Highest revision applied so far. Starts at -1 so revision 0 is the first
    /// accepted one. A response carrying a revision at or below this is stale
    /// and must be dropped — otherwise a slow earlier request landing late
    /// would rewind text the audience has already read.
    private(set) var revision: Int = -1

    /// Indices whose text changed while already committed — the correction case
    /// the UI animates. The view clears these once rendered.
    var correctedIndices: Set<Int> = []

    /// True once the source is final and the last translation pass completed.
    /// Only settled text is persisted to disk or uploaded.
    private(set) var settled: Bool = false

    var committed: ArraySlice<String> { words.prefix(effectiveCommittedCount) }
    var provisional: ArraySlice<String> { words.dropFirst(effectiveCommittedCount) }

    var rendered: String { words.joined(separator: " ") }
    var committedText: String { committed.joined(separator: " ") }
    var provisionalText: String { provisional.joined(separator: " ") }

    var isEmpty: Bool { words.isEmpty }

    /// True once a translation pass has begun for this utterance — what
    /// distinguishes "not translated yet" from "translated to nothing".
    ///
    /// An explicit flag rather than `revision >= 0`: `restart()`,
    /// `applyStreaming()` and `clear()` all mean the translation has started but
    /// none of them completes a *revision*, so deriving it from the counter made
    /// a streaming row report `.finalized` and left a cleared filler row stuck
    /// there permanently.
    private(set) var hasStarted: Bool = false

    /// Apply a speculative revision, running the consensus merge.
    /// Returns false when the revision was stale (or the text already settled)
    /// and was therefore ignored.
    @discardableResult
    mutating func apply(revision newRevision: Int, text: String) -> Bool {
        guard !settled, newRevision > revision else { return false }
        hasStarted = true
        let next = Self.tokenize(text)
        // previous: revisionWords, NOT words — words already holds this very pass's
        // streamed text, so merging against it compares the pass with itself.
        let merged = PrefixConsensus.merge(
            previous: revisionWords, next: next, frontier: committedCount)
        words = next
        revisionWords = next
        committedCount = merged.frontier
        correctedIndices = merged.corrected
        revision = newRevision
        return true
    }

    /// Update the text mid-stream WITHOUT running consensus.
    ///
    /// Tokens arrive one at a time, but a "revision" is a whole completed
    /// translation pass — running consensus per token would make every token its
    /// own revision and commit words on the strength of nothing. So streaming
    /// tokens only ever extend the provisional tail; `apply(revision:text:)`
    /// decides what becomes committed when the pass finishes.
    ///
    /// `committedCount` is preserved untouched so already-committed words do not
    /// flicker back to grey while the tail types out — including across the
    /// hypothesis-to-final boundary, where `words` briefly holds fewer tokens
    /// than the frontier refers to.
    mutating func applyStreaming(text: String) {
        guard !settled else { return }
        hasStarted = true
        let streamed = Self.tokenize(text)
        // Show the last completed revision until the incoming stream has caught up
        // to the committed region, then switch to the stream wholesale.
        //
        // Two wrong answers were tried first. Assigning `words = streamed`
        // unconditionally kept the frontier count but threw away the committed
        // *text*, so the final pass — which streams in from empty — turned a
        // 4-word committed prefix into a one-word line that then regrew: the
        // visible reset the carry-over exists to prevent. Splicing
        // `revisionWords.prefix(committedCount) + streamed.dropFirst(committedCount)`
        // fixed the shrink but assumed word index N of the new translation
        // corresponds to word index N of the old one. It usually does not — a
        // revision that inserts or drops a word ahead of the frontier shifts
        // everything after it — so the splice dropped or duplicated words on the
        // guest-facing screen.
        //
        // Swapping whole arrays never invents or loses a word. The cost is that the
        // previous revision stays up a beat longer, which is exactly what it is for.
        words = streamed.count >= committedCount ? streamed : revisionWords
        // committedCount is deliberately NOT clamped here — see its doc.
    }

    /// The source is final and this is the last pass: commit everything and
    /// stop accepting revisions. Corrections are still reported so a final
    /// text that contradicts committed words animates rather than jumping.
    mutating func settle(text: String) {
        hasStarted = true
        let next = Self.tokenize(text)
        let merged = PrefixConsensus.merge(
            previous: revisionWords, next: next, frontier: committedCount)
        words = next
        revisionWords = next
        correctedIndices = merged.corrected
        committedCount = next.count
        revision += 1
        settled = true
    }

    /// Discard everything streamed so far — used when a translation is retried
    /// with skipping forbidden, so the discarded ∅ can't linger.
    mutating func restart() {
        // A retry is still a translation in progress — it must not read as
        // "not started" while the second pass streams in.
        hasStarted = true
        words = []
        revisionWords = []
        committedCount = 0
        correctedIndices = []
        settled = false
    }

    /// Throw away the in-flight stream and show the last COMPLETED revision again.
    ///
    /// For a speculative pass that came back unusable — a refusal, a placeholder — where
    /// the row must stop displaying it but the sentence is still being spoken. Neither
    /// existing reset fits: `clear()` marks the text settled, which would freeze a live
    /// hypothesis as finished, and `restart()` zeroes `committedCount`, which destroys
    /// words two revisions already agreed on and produces exactly the visible reset that
    /// the carry-over exists to prevent.
    ///
    /// Restores from `revisionWords`, not from `words.prefix(committedCount)`.
    /// `applyStreaming` switches to the incoming stream *wholesale* once it passes the
    /// committed region, so by the time a refusal has streamed in, the prefix of `words`
    /// is the refusal's own opening words — reverting to that would keep "I'm unable to"
    /// on screen and call it committed. `revisionWords` is the last text that actually
    /// completed a revision, which is the only trustworthy thing left to show.
    mutating func revertToLastRevision() {
        guard !settled else { return }
        words = revisionWords
        correctedIndices = []
    }

    /// Drop the translation entirely (filler utterance) and mark it done, so
    /// the row shows source-only and never sits in a "translating" state.
    mutating func clear() {
        hasStarted = true
        words = []
        revisionWords = []
        committedCount = 0
        correctedIndices = []
        settled = true
    }

    /// Whitespace tokenization. Korean eojeol are space-delimited, so one rule
    /// serves both directions.
    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
