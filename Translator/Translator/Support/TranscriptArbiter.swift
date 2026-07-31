import Foundation

/// Tier 2 of transcript arbitration: the pure, network-free rule that picks
/// which engine's transcript wins when both are listening to the same audio.
///
/// The tiers, and why this one exists:
///   1. `ScriptDetector` — "what writing system is this", per frame, free.
///   2. `TranscriptArbiter` — this type. Still cheap enough to run on every
///      frame, including partial hypotheses that a later frame will replace.
///   3. An LLM judge — accurate, but a network round trip and real money per
///      call. This type never invokes it; it only *recommends* it by returning
///      `.needsJudge`, leaving the caller to decide whether an utterance is
///      worth the spend (finals yes, still-mutating hypotheses no).
///
/// Keeping tier 2 a pure function over its inputs is load-bearing: every rule
/// below is testable without a live socket, and arbitration can be re-run on a
/// revised transcript without a second API bill.
///
/// The asymmetry the whole rule set turns on: RTZR runs `sommers_ko` and
/// nothing else. It has no English model, so English audio comes back as
/// Hangul that *reads* like fluent Korean — plausible syllables, wrong words,
/// often a high confidence score. OpenAI Realtime is the opposite trade:
/// weaker on Korean business vocabulary, but it can say which language it
/// heard. That makes "which engine is on home turf for what it claims to have
/// heard" a far better question than "which engine is more confident", which
/// is why confidence only ever appears here as a last-resort tie-break.
enum TranscriptArbiter {

    /// One engine's transcript for the same slice of audio.
    struct Candidate: Equatable, Sendable {
        let engine: STTEngine
        let text: String
        let confidence: Double?
        /// Language the engine claimed, nil if it didn't say. RTZR never says —
        /// it only has one model, so it has nothing to report.
        let reportedLanguage: Language?

        init(
            engine: STTEngine,
            text: String,
            confidence: Double? = nil,
            reportedLanguage: Language? = nil
        ) {
            self.engine = engine
            self.text = text
            self.confidence = confidence
            self.reportedLanguage = reportedLanguage
        }

        /// Adapt a wire message. `bestText` is already trimmed and is nil for
        /// an empty alternative, which collapses to "" so rule 1 drops it
        /// instead of the caller having to pre-filter.
        init(_ message: STTMessage) {
            self.init(
                engine: message.engine,
                text: message.bestText ?? "",
                confidence: message.confidence,
                reportedLanguage: message.language
            )
        }

        /// Resolved: what the engine claimed, else what the writing system
        /// implies. nil only when the text carries no letters at all ("12:30",
        /// "…"), which is undecidable rather than wrong.
        var language: Language? {
            reportedLanguage ?? ScriptDetector.language(of: text)
        }

        /// Whitespace-only counts as empty: RTZR emits blank alternatives
        /// during silence and OpenAI emits a lone space at segment edges.
        var isEmpty: Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    enum Decision: Equatable, Sendable {
        /// Use this candidate's transcript. Cheap path.
        case pick(STTEngine)
        /// Both agree on the language but disagree materially on the words —
        /// worth spending an LLM judge call on. The language rides along
        /// because the judge prompt needs to know which direction it is
        /// arbitrating in.
        case needsJudge(Language)
        /// Nothing usable (all candidates empty).
        case discard
    }

    /// Tunable: above this token-level divergence, same-language candidates
    /// are considered materially different.
    ///
    /// Roughly "more than a third of the eojeol disagree". Below that, the two
    /// engines heard the same sentence and merely spell it differently (particle
    /// choice, honorific ending, a compound split in two), and the specialist's
    /// reading is the better bet. Above it they heard different sentences, and
    /// no local rule can tell which — that is what the judge tier is for.
    /// Compared with strict `>`, so a divergence exactly at the threshold is
    /// still treated as agreement.
    static let materialDivergence: Double = 0.34

    /// Decide which transcript to believe. Pure: no network, no clock, no
    /// shared state, so the caller can run it per frame and per revision.
    static func decide(_ candidates: [Candidate]) -> Decision {
        // Rule 1 — an engine with nothing to say is not a dissenting opinion.
        // Empties are dropped *before* deduplication so that a blank frame
        // from an engine cannot erase that same engine's earlier real text.
        let usable = collapsingRepeats(candidates.filter { !$0.isEmpty })
        guard !usable.isEmpty else { return .discard }

        // Rule 2 — a single survivor wins by default. Even romanization
        // garbage beats showing the audience nothing.
        if usable.count == 1 { return .pick(usable[0].engine) }

        // Only candidates whose language is decidable can take part in a
        // language argument (rules 3-5). "12" and "…" carry no evidence about
        // *which* language was spoken, so they are set aside rather than
        // allowed to manufacture a disagreement.
        let decided = usable.filter { $0.language != nil }
        guard !decided.isEmpty else {
            // Rule 6 — nobody's script is readable. Confidence is all that is
            // left to go on.
            guard let winner = mostConfident(usable) else { return .discard }
            return .pick(winner.engine)
        }
        if decided.count == 1 { return .pick(decided[0].engine) }

        let languages = Set(decided.compactMap { $0.language })
        if languages.count > 1 {
            // Rule 3 — the engines disagree about what language was spoken.
            // Believe whichever one is on home turf for what IT heard; see
            // `crossLanguageAuthority`.
            guard let winner = mostAuthoritative(decided) else { return .discard }
            return .pick(winner.engine)
        }

        guard let language = languages.first else { return .discard }
        switch language {
        case .ko:
            return koreanDecision(decided)
        case .en:
            return englishDecision(decided)
        }
    }

    // MARK: - Same-language rules

    /// Rule 4 — everyone heard Korean.
    ///
    /// RTZR is the specialist here (business-tuned, keyword boosting), so it
    /// wins by default. The exception is a material disagreement: when the
    /// generalist heard a substantially different sentence, one of them
    /// mis-heard a whole clause, and picking the specialist on reputation alone
    /// would happily publish a confident wrong number into a meeting. That is
    /// the one case worth paying an LLM judge for.
    private static func koreanDecision(_ candidates: [Candidate]) -> Decision {
        guard let specialist = candidates.first(where: {
            $0.engine.nativeLanguage == .ko
        }) else {
            // No Korean specialist in the running (both generalists) — nothing
            // to arbitrate on reputation, so fall back to confidence.
            guard let winner = mostConfident(candidates) else { return .discard }
            return .pick(winner.engine)
        }
        let rivals = candidates.filter { $0.engine != specialist.engine }
        // Corroboration by *any* rival is enough; only unanimous material
        // disagreement escalates.
        guard let closest = rivals.map({ divergence(specialist.text, $0.text) }).min()
        else { return .pick(specialist.engine) }
        return closest > materialDivergence
            ? .needsJudge(.ko)
            : .pick(specialist.engine)
    }

    /// Rule 5 — everyone heard English.
    ///
    /// RTZR is structurally incapable of English output, so if it is showing
    /// English there is nothing to arbitrate: the only candidate that *could*
    /// be right is one whose engine has an English model. Deliberately never
    /// returns `.needsJudge` — a judge cannot conjure an English transcript out
    /// of an engine that does not have one, so the call would be pure cost.
    private static func englishDecision(_ candidates: [Candidate]) -> Decision {
        // A generalist (`nativeLanguage == nil`) handles both languages; an
        // engine explicitly native to English would qualify too, if one is
        // ever added.
        let capable = candidates.filter {
            $0.engine.nativeLanguage == nil || $0.engine.nativeLanguage == .en
        }
        let pool = capable.isEmpty ? candidates : capable
        guard let winner = mostConfident(pool) else { return .discard }
        return .pick(winner.engine)
    }

    // MARK: - Ranking helpers

    /// How much weight a candidate's language claim carries when the engines
    /// disagree about the language itself. Higher wins.
    ///
    /// The classic case is RTZR saying Korean (2) while OpenAI says English
    /// (3): the audio really was English, RTZR simply cannot say so, and its
    /// Hangul is romanization noise. An English claim from the only engine that
    /// can produce English therefore outranks the specialist's home-turf claim.
    /// The mirror case — a specialist emitting text outside its own language
    /// (0), e.g. RTZR returning Latin letters — is the strongest possible
    /// signal that it is off the rails.
    private static func crossLanguageAuthority(_ candidate: Candidate) -> Int {
        guard let heard = candidate.language else { return 0 }
        guard let native = candidate.engine.nativeLanguage else {
            // Generalist: competent in either language, and the sole possible
            // source of English.
            return heard == .en ? 3 : 2
        }
        return native == heard ? 2 : 0
    }

    /// Winner of a cross-language dispute: highest authority, then confidence,
    /// then the generalist.
    private static func mostAuthoritative(_ candidates: [Candidate]) -> Candidate? {
        candidates.max {
            (crossLanguageAuthority($0), confidenceKey($0), generalistKey($0))
                < (crossLanguageAuthority($1), confidenceKey($1), generalistKey($1))
        }
    }

    /// Highest confidence wins; ties break to the generalist (rule 6's
    /// documented tie-break toward OpenAI).
    private static func mostConfident(_ candidates: [Candidate]) -> Candidate? {
        candidates.max {
            (confidenceKey($0), generalistKey($0))
                < (confidenceKey($1), generalistKey($1))
        }
    }

    /// Missing confidence sorts below every real score, including 0.0. An
    /// engine that simply does not report confidence must not out-rank one
    /// that does — treating nil as "perfect" (or as 0.5) would let a silent
    /// engine win arguments it never made a claim in.
    private static func confidenceKey(_ candidate: Candidate) -> Double {
        candidate.confidence ?? -1
    }

    private static func generalistKey(_ candidate: Candidate) -> Int {
        candidate.engine.nativeLanguage == nil ? 1 : 0
    }

    /// Collapse repeats of the same engine, last wins.
    ///
    /// The pipeline normally hands over the latest frame per engine, but a
    /// reconnect can replay a message before the stale one is dropped; the
    /// later transcript reflects more audio. Position follows first appearance
    /// so the tie-breaks stay deterministic regardless of replay order.
    private static func collapsingRepeats(_ candidates: [Candidate]) -> [Candidate] {
        var result: [Candidate] = []
        for candidate in candidates {
            if let index = result.firstIndex(where: { $0.engine == candidate.engine }) {
                result[index] = candidate
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    // MARK: - Divergence

    /// Normalized Levenshtein distance 0...1 over whitespace-separated tokens.
    ///
    /// Tokens, not characters: Korean eojeol and English words are the unit a
    /// listener would call "a different word". Character distance would rate
    /// "매출은/매출이" as a near-identical pair (1 of 3 chars) when it can flip
    /// the subject of the sentence, and would rate the honorific endings
    /// "합니다/했습니다" as a big change when it is the same verb.
    ///
    /// Returns 0 for identical (including two empty inputs) and 1 when nothing
    /// lines up, and never traps on empty input.
    static func divergence(_ a: String, _ b: String) -> Double {
        let lhs = tokens(a)
        let rhs = tokens(b)
        if lhs.isEmpty, rhs.isEmpty { return 0 }
        guard !lhs.isEmpty, !rhs.isEmpty else { return 1 }
        let distance = editDistance(lhs, rhs)
        // Unit-cost Levenshtein never exceeds the longer length, so this is
        // already in 0...1 without clamping.
        return Double(distance) / Double(max(lhs.count, rhs.count))
    }

    /// Whitespace-separated tokens, lowercased and stripped of edge punctuation.
    ///
    /// Case and edge punctuation are exactly what the two engines disagree
    /// about constantly ("Okay," vs "okay", "어렵습니다" vs "어렵습니다.") while
    /// meaning the same word. Folding them keeps cosmetic diffs from pushing an
    /// otherwise-agreeing pair over `materialDivergence` and billing a judge
    /// call for a comma.
    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map {
                String($0)
                    .trimmingCharacters(in: .punctuationCharacters)
                    .lowercased()
            }
            .filter { !$0.isEmpty }
    }

    /// Two-row Wagner-Fischer. Utterances are short, but this runs per STT
    /// frame for every engine pair, so keep it O(min(n, m)) memory instead of
    /// allocating a full matrix each time.
    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,          // deletion
                    current[j - 1] + 1,       // insertion
                    previous[j - 1] + cost    // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
