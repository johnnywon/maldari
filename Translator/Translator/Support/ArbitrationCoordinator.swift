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

    /// Staleness bound on the challenger buffer — a **memory guard, not a
    /// matching rule**.
    ///
    /// The segment boundary (`lastSegmenterAt`) decides what belongs to what. A
    /// time window cannot: RTZR runs `max_utter_duration=5` and emits a final
    /// every 5 seconds through continuous speech, while OpenAI's server VAD has no
    /// maximum turn length and runs as long as the speaker does. So the span a
    /// segment covers is unbounded, and *any* fixed window eventually prunes the
    /// start of a long utterance. The first attempt used 1.5s and lost everything
    /// but the last ~2 seconds of a 12-second sentence: the fragment competed
    /// against the full segment, divergence hit ~0.8, the arbiter escalated, and
    /// the cheap pick — which prefers the Korean specialist — published the
    /// fragment as the whole utterance. Ten of twelve seconds vanished from the
    /// screen, the export and the cloud.
    ///
    /// This value therefore only stops the buffer growing without bound if the
    /// segmenter dies mid-sentence and never closes a segment.
    static let staleAfter: TimeInterval = 30

    /// A challenger arriving within this long after a segmenter final is treated
    /// as a LATE transcript of the segment that just resolved, and dropped.
    ///
    /// The engines race, so either can win. Arrival time alone cannot distinguish
    /// "RTZR's transcript of the sentence we just published" from "RTZR's
    /// transcript of the next sentence, which started immediately" — and audio
    /// time is no help because OpenAI's messages carry no duration. Carrying it
    /// forward was the worse guess: the next utterance got arbitrated against the
    /// previous utterance's words, divergence hit ~1.0, and the cheap pick
    /// published the PREVIOUS sentence in place of the one just spoken. One line
    /// lost, another duplicated. Dropping it merely forfeits one arbitration.
    static let lateChallengerGrace: TimeInterval = 0.6

    /// Rolling transcripts handed to the judge as context.
    private static let contextDepth = 4

    private struct Buffered {
        let at: Date
        let message: STTMessage
    }

    private var challengers: [Buffered] = []
    private var recentContext: [String] = []
    private let judge: TranscriptJudging

    /// When the previous segmenter final arrived — the boundary between one
    /// utterance's competitor set and the next.
    ///
    /// Without it, a challenger that lands *after* its own segmenter final (the
    /// engines race, and either can win) stays in the buffer and is matched
    /// against the NEXT segmenter final. The next utterance is then arbitrated
    /// against the previous utterance's transcript, divergence is ~1.0, the
    /// arbiter escalates, and the cheap pick publishes the PREVIOUS sentence in
    /// place of the one just spoken — losing one line and duplicating another.
    private var lastSegmenterAt: Date?

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
        lastSegmenterAt = nil
    }

    // MARK: - Ingestion

    /// A challenger engine finalized. Buffer it; it competes for the text of
    /// the next segmenter final that closes a segment.
    func ingestChallenger(_ message: STTMessage, at now: Date = Date()) {
        guard message.isFinal, message.bestText != nil else { return }
        prune(now)
        // Late transcript of the segment that just resolved — see
        // `lateChallengerGrace`. Forfeit the arbitration rather than risk
        // attributing it to the next sentence.
        if let boundary = lastSegmenterAt,
           now.timeIntervalSince(boundary) <= Self.lateChallengerGrace {
            DiagnosticLog.shared.info("stt", "challenger_late", [
                "engine": message.engine.rawValue,
                "after_segment_s": now.timeIntervalSince(boundary),
                "text": String((message.bestText ?? "").prefix(60)),
            ])
            return
        }
        challengers.append(Buffered(at: now, message: message))
    }

    /// The segmenter produced a message. Partials pass straight through; finals
    /// are arbitrated against whatever challengers are in the window.
    func ingestSegmenter(_ message: STTMessage, at now: Date = Date()) {
        guard message.isFinal, let segmenterText = message.bestText else {
            if message.isFinal {
                // An empty final still closes a segment. Dropping out here without
                // advancing the boundary and clearing the buffer would leave this
                // segment's challengers to bleed into the next utterance.
                challengers.removeAll()
                lastSegmenterAt = now
            }
            // Partial, or an empty final that just clears the hypothesis line.
            onResolved?(message)
            return
        }
        prune(now)

        // Everything buffered since the previous segment closed belongs to this
        // one. No time window: the span a segment covers is unbounded, so any
        // window silently truncates long utterances (see `staleAfter`).
        //
        // RTZR may have cut the same speech into several finals where OpenAI made
        // one (its 5s forced-segment cap), so concatenate rather than pick —
        // otherwise a fragment competes against a whole sentence and always looks
        // maximally divergent.
        let boundary = lastSegmenterAt
        let matched = challengers.filter { boundary == nil || $0.at > boundary! }
        // Consume everything up to this moment regardless of whether it matched:
        // anything older is either already used or too stale to be trusted, and
        // leaving it behind is how a transcript bleeds into a later utterance.
        challengers.removeAll { $0.at <= now }
        lastSegmenterAt = now

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

    /// Only drops transcripts so old that the segmenter must have died without
    /// closing a segment. Ordinary lifecycle is the boundary, not the clock.
    private func prune(_ now: Date) {
        challengers.removeAll { now.timeIntervalSince($0.at) > Self.staleAfter }
    }
}
