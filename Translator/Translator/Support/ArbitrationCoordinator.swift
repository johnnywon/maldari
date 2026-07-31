import Foundation

/// Reconciles two STT engines listening to the same audio into one utterance
/// stream, so `TranscriptArbiter` compares like with like.
///
/// ## Why this is not symmetric
///
/// The two engines segment independently — RTZR runs its own end-point detection
/// (epd_time 0.5s, max_utter_duration 5s) and OpenAI Realtime runs server VAD —
/// so their finals do not arrive paired, in step, or even one-to-one. Rather than
/// try to align two independent segmentations, one engine is the **segmenter of
/// record** and the other is a challenger:
///
/// - **OpenAI segments.** It is the only engine valid for both languages, so its
///   boundaries hold no matter who is speaking. RTZR's boundaries on English
///   audio would be driven by whatever garbage its Korean model produced.
/// - **RTZR challenges finals only.** Its transcript competes for the text, never
///   for the boundaries.
/// - **Partials come from the segmenter alone.** Forwarding both would make the
///   single hypothesis line flip-flop between two engines' guesses mid-word.
///   RTZR's partials are slightly faster; that latency is the price of a stable
///   line, and it is the right trade on a guest-facing screen.
///
/// ## Two-tier emission
///
/// `onResolved` fires immediately with the cheap deterministic pick so the screen
/// updates without waiting on anything. If the arbiter asked for a judge and the
/// judge later overrules, `onCorrected` fires with the better transcript. That is
/// the same show-fast-then-correct contract the translation layer uses.
@MainActor
final class ArbitrationCoordinator {

    /// How long a challenger stays eligible to be matched against a segmenter
    /// final. The engines finalize the same speech within roughly a second of
    /// each other; 1.5s absorbs the jitter without letting a stale transcript
    /// from the previous sentence contaminate the next one.
    ///
    /// Tunable, and untuned: this wants adjusting against real meeting audio.
    static let matchWindow: TimeInterval = 1.5

    /// Rolling transcripts handed to the judge as context.
    private static let contextDepth = 4

    private struct Buffered {
        let at: Date
        let message: STTMessage
    }

    private var challengers: [Buffered] = []
    private var recentContext: [String] = []
    private let judge: TranscriptJudging

    /// The reconciled message, emitted immediately.
    var onResolved: ((STTMessage) -> Void)?

    /// Fired only when the LLM judge overruled the cheap pick, after the fact.
    /// `(utteranceID, betterText, language)`.
    var onCorrected: ((Int, String, Language) -> Void)?

    init(judge: TranscriptJudging = NoopTranscriptJudge()) {
        self.judge = judge
    }

    func reset() {
        challengers.removeAll()
        recentContext.removeAll()
    }

    // MARK: - Ingestion

    /// A challenger engine finalized. Buffer it; it competes for the text of
    /// whichever segmenter final arrives next inside `matchWindow`.
    func ingestChallenger(_ message: STTMessage, at now: Date = Date()) {
        guard message.isFinal, message.bestText != nil else { return }
        prune(now)
        challengers.append(Buffered(at: now, message: message))
    }

    /// The segmenter produced a message. Partials pass straight through; finals
    /// are arbitrated against whatever challengers are in the window.
    func ingestSegmenter(_ message: STTMessage, at now: Date = Date()) {
        guard message.isFinal, let segmenterText = message.bestText else {
            // Partial, or an empty final that just clears the hypothesis line.
            onResolved?(message)
            return
        }
        prune(now)

        // Every challenger still in the window belongs to this utterance. RTZR
        // may have cut the same speech into two finals where OpenAI made one, so
        // concatenate rather than pick — otherwise half a sentence gets compared
        // against a whole one and always looks wrong.
        let matched = challengers.filter { now.timeIntervalSince($0.at) <= Self.matchWindow }
        challengers.removeAll { now.timeIntervalSince($0.at) <= Self.matchWindow }

        var candidates: [TranscriptArbiter.Candidate] = [
            TranscriptArbiter.Candidate(
                engine: message.engine,
                text: segmenterText,
                confidence: message.confidence,
                reportedLanguage: message.language)
        ]

        if !matched.isEmpty {
            let joined = matched
                .compactMap { $0.message.bestText }
                .joined(separator: " ")
            // Average the challengers' confidences; a concatenation has no single
            // confidence of its own.
            let confidences = matched.compactMap { $0.message.confidence }
            let averaged = confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Double(confidences.count)
            candidates.append(TranscriptArbiter.Candidate(
                engine: matched[0].message.engine,
                text: joined,
                confidence: averaged,
                reportedLanguage: matched[0].message.language))
        }

        let decision = TranscriptArbiter.decide(candidates)
        DiagnosticLog.shared.info("stt", "arbitrated", [
            "seq": message.seq,
            "candidates": candidates.count,
            "decision": String(describing: decision),
            "segmenter": String(segmenterText.prefix(60)),
            "challenger": String((candidates.count > 1 ? candidates[1].text : "").prefix(60)),
        ])

        // Cheap pick, emitted now.
        let cheap = Self.cheapWinner(decision, candidates: candidates) ?? candidates[0]
        emit(cheap, from: message)

        // Tier 2 only when the arbiter asked for it.
        if case .needsJudge(let language) = decision, candidates.count > 1 {
            let context = recentContext
            let id = message.seq
            let judge = self.judge
            Task { @MainActor [weak self] in
                guard let winner = await judge.judge(
                    candidates: candidates, language: language, context: context)
                else { return }
                guard let better = candidates.first(where: { $0.engine == winner }),
                      better.text != cheap.text else { return }
                DiagnosticLog.shared.info("stt", "judge_overruled", [
                    "seq": id,
                    "from": cheap.engine.rawValue,
                    "to": winner.rawValue,
                ])
                self?.recordContext(better.text)
                self?.onCorrected?(id, better.text, better.language ?? language)
            }
        }
    }

    // MARK: - Internals

    /// The transcript to show immediately. For `.needsJudge` that is the
    /// specialist's text — the judge is asked to overturn a reasonable default,
    /// not to break a tie from nothing.
    private static func cheapWinner(
        _ decision: TranscriptArbiter.Decision,
        candidates: [TranscriptArbiter.Candidate]
    ) -> TranscriptArbiter.Candidate? {
        switch decision {
        case .pick(let engine):
            return candidates.first { $0.engine == engine }
        case .needsJudge(let language):
            // Prefer the engine native to the agreed language, else the first.
            return candidates.first { $0.engine.nativeLanguage == language }
                ?? candidates.first
        case .discard:
            return nil
        }
    }

    private func emit(_ winner: TranscriptArbiter.Candidate, from original: STTMessage) {
        recordContext(winner.text)
        onResolved?(STTMessage(
            seq: original.seq,
            startAt: original.startAt,
            duration: original.duration,
            isFinal: true,
            text: winner.text,
            confidence: winner.confidence,
            engine: winner.engine,
            // Pin the resolved language so downstream never re-derives it and
            // reaches a different answer than the arbiter did.
            language: winner.language))
    }

    private func recordContext(_ text: String) {
        recentContext.append(text)
        if recentContext.count > Self.contextDepth {
            recentContext.removeFirst(recentContext.count - Self.contextDepth)
        }
    }

    private func prune(_ now: Date) {
        challengers.removeAll { now.timeIntervalSince($0.at) > Self.matchWindow }
    }
}
