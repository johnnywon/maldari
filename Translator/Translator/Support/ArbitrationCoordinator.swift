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

    /// How much longer than the segmenter's text a challenger may be before it is
    /// assumed to span more than this segment and dropped from the competition.
    /// 1.6x tolerates ordinary wording differences between two engines without
    /// tolerating a transcript that covers two sentences.
    static let maxChallengerOverrun: Double = 1.6

    /// The mirror bound: a challenger far SHORTER than the segmenter is covering
    /// only part of the segment, and publishing it drops the rest of the sentence.
    /// Only the overrun side was guarded at first, which left the truncation case —
    /// the very failure the boundary rule was introduced to fix — reachable by
    /// another route whenever RTZR dropped a forced segment.
    static let minChallengerCoverage: Double = 0.6

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

    /// Fired once per utterance when nothing further can change its transcript:
    /// immediately when no judge was needed, or after the judge has ruled either
    /// way. This is what promotes a source from `.draft` to `.arbitrated`.
    ///
    /// Needed because `onResolved` fires *before* the judge runs. Confirming there
    /// would claim a transcript is final while a correction is still in flight;
    /// not confirming at all left every utterance in single-mic mode permanently
    /// `.draft`, so the Presentation window's completion rule never fired.
    var onArbitrationComplete: ((Int) -> Void)?

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
                // An empty final still closes a segment. Dropping out without
                // advancing the boundary and clearing the buffer would leave this
                // segment's challengers to bleed into the next utterance.
                //
                // But if a challenger DID hear something, the segmenter having heard
                // nothing is not a reason to discard a whole spoken line — that is
                // the arbiter's "single survivor wins" rule, and skipping it lost
                // the line entirely. Emit the challenger in the segmenter's place.
                let salvage = challengers
                    .filter { boundaryAllows($0, now: now) }
                    .compactMap { $0.message.bestText }
                    .joined(separator: " ")
                challengers.removeAll()
                lastSegmenterAt = now
                if !salvage.isEmpty {
                    let language = ScriptDetector.language(of: salvage) ?? .ko
                    DiagnosticLog.shared.info("stt", "salvaged_from_challenger", [
                        "seq": message.seq,
                        "text": String(salvage.prefix(60)),
                    ])
                    recordContext(salvage)
                    onResolved?(STTMessage(
                        seq: message.seq, startAt: message.startAt,
                        duration: message.duration, isFinal: true, text: salvage,
                        engine: .rtzr, language: language))
                    onArbitrationComplete?(message.seq)
                    return
                }
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
        let matched = challengers.filter { boundaryAllows($0, now: now) }
        // Consume everything up to this moment regardless of whether it matched:
        // anything older is either already used or too stale to be trusted, and
        // leaving it behind is how a transcript bleeds into a later utterance.
        challengers.removeAll { $0.at <= now }
        lastSegmenterAt = now

        var candidatesSkipChallenger = false
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
            // A challenger whose text runs far past the segmenter's is covering more
            // than this segment — the mirror image of the truncation case. RTZR can
            // produce one long final spanning several OpenAI segments, and letting
            // that win republishes speech already on screen, duplicating a line. The
            // segmenter owns the boundaries, so a challenger that disagrees about
            // *how much was said* is not a candidate for what was said.
            let ratio = Double(joined.count) / Double(max(1, segmenterText.count))
            if ratio > Self.maxChallengerOverrun || ratio < Self.minChallengerCoverage {
                DiagnosticLog.shared.info("stt", "challenger_span_mismatch", [
                    "seq": message.seq,
                    "segmenter_chars": segmenterText.count,
                    "challenger_chars": joined.count,
                    "ratio": ratio,
                ])
                candidatesSkipChallenger = true
            }
            // Average the challengers' confidences; a concatenation has no single
            // confidence of its own.
            let confidences = matched.compactMap { $0.message.confidence }
            let averaged = confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Double(confidences.count)
            if !candidatesSkipChallenger {
                candidates.append(TranscriptArbiter.Candidate(
                    engine: matched[0].message.engine,
                    text: joined,
                    confidence: averaged,
                    reportedLanguage: matched[0].message.language))
            }
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
        guard case .needsJudge(let language) = decision, candidates.count > 1 else {
            // Nothing further can change this transcript.
            onArbitrationComplete?(message.seq)
            return
        }
        let context = recentContext
        let id = message.seq
        let judge = self.judge
        Task { @MainActor [weak self] in
            let winner = await judge.judge(
                candidates: candidates, language: language, context: context)
            // Complete either way: the judge abstaining is still a final answer,
            // and leaving it unconfirmed would strand the utterance in `.draft`.
            defer { self?.onArbitrationComplete?(id) }
            guard let winner,
                  let better = candidates.first(where: { $0.engine == winner }),
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

    /// Whether a buffered challenger belongs to the segment now closing.
    ///
    /// Arriving after the previous boundary is necessary but not sufficient: a
    /// challenger that landed 0.6–30s after its OWN segmenter final (past the late
    /// grace, inside the staleness bound) also satisfies that, and used to be
    /// matched against the next segment — carrying the previous sentence's words
    /// into it. Requiring it to also predate this segmenter final by less than the
    /// grace period is wrong (it would drop everything), so instead the boundary is
    /// advanced on EVERY segmenter final and the buffer is drained there, which
    /// leaves this predicate covering only genuinely-current transcripts.
    private func boundaryAllows(_ candidate: Buffered, now: Date) -> Bool {
        guard let boundary = lastSegmenterAt else { return true }
        return candidate.at > boundary
    }

    /// Only drops transcripts so old that the segmenter must have died without
    /// closing a segment. Ordinary lifecycle is the boundary, not the clock.
    private func prune(_ now: Date) {
        challengers.removeAll { now.timeIntervalSince($0.at) > Self.staleAfter }
    }
}
