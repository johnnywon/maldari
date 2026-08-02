import Foundation

/// Single source of truth for the live transcript. STT messages flow in via
/// `apply(_:)`; the UI observes `utterances` + `partials`; finalized utterances
/// are handed to `onFinalized` so the pipeline can enqueue translation.
///
/// Translation is **revision-based**, not append-only. A speculative pass
/// replaces the whole target text and `SpeculativeText` decides which words are
/// committed, so an early guess can be corrected without the audience watching
/// settled text rearrange itself.
@MainActor
@Observable
final class TranscriptStore {
    private(set) var utterances: [Utterance] = []
    /// The current mutating hypothesis, rendered as a single gray line pinned
    /// at the bottom of the transcript. Mutates in place per seq.
    private(set) var partials: [Utterance] = []

    var sessionStart: Date?

    /// Fired when an engine locks an utterance (final=true, non-empty text).
    var onFinalized: ((Utterance) -> Void)?

    /// Fired whenever the live hypothesis changes. The pipeline's speculative
    /// translator watches this to decide whether the sentence has grown enough to
    /// be worth another pass. A callback rather than @Observable because the
    /// decision is rate-limited and stateful, not a view update.
    var onPartialUpdated: ((Utterance) -> Void)?

    /// O(1) id → array index lookup so per-token operations don't scan the
    /// entire array. Maintained alongside `utterances` on every mutation.
    private var indexByID: [Int: Int] = [:]

    /// Id of the most recently *finalized* utterance.
    ///
    /// `utterances.last` is NOT the same thing, and assuming it is caused a real
    /// bug: finals are backdated by their reported duration and inserted by
    /// timestamp, and only RTZR reports a duration (OpenAI's messages carry
    /// `duration: nil`). In dual mode both engines insert into this one array, so
    /// a 5-second Korean sentence can be inserted at index 0 while a later but
    /// shorter English "okay" remains at the end — and a view keyed on `.last`
    /// then shows "okay" as the live line while the sentence the room actually
    /// heard is demoted into history. Anything that means "the sentence just
    /// spoken" must use this.
    private(set) var newestFinalizedID: Int?

    var newestFinalized: Utterance? {
        guard let id = newestFinalizedID, let idx = indexByID[id] else { return nil }
        return utterances[idx]
    }

    // MARK: - STT ingestion

    func apply(_ message: STTMessage, at date: Date = Date()) {
        guard let text = message.bestText else {
            // Empty hypothesis: a final with no text clears THIS CHANNEL's partial
            // only. `removeAll()` destroyed the other channel's live hypothesis —
            // and with it any committed speculative translation it had accumulated —
            // every time one engine emitted an empty final, which it does routinely
            // on silence.
            if message.isFinal {
                partials.removeAll { Self.band($0.id) == Self.band(message.seq) }
                if lastPartialID == message.seq { lastPartialID = partials.last?.id }
            }
            return
        }

        // Which language this is. Falls back to Korean so `koreanOnly` mode
        // behaves exactly as before, when no engine reported a language and
        // every transcript was Korean by construction.
        let language = message.resolvedLanguage ?? .ko

        if message.isFinal {
            // Guard against duplicate finals for the same seq. Checked before the
            // partial is dropped so a duplicate can't wipe the hypothesis line.
            guard indexByID[message.seq] == nil else { return }
            // Carry the speculative translation across the finalization boundary:
            // words already committed while the sentence was still a hypothesis
            // stay committed, so the translation does not visibly reset the
            // instant the speaker stops talking.
            // Carry the speculative translation forward ONLY if it was produced in
            // the same direction. A hypothesis whose detected language flipped
            // mid-sentence (a Korean line opening with a number reads as English for
            // its first deltas) accumulated a translation into the OTHER language,
            // and carrying that over presented text in the wrong language as
            // committed — in the wrong column, in the settled accent colour.
            let priorPartial = partials.first { $0.id == message.seq }
            let carried = priorPartial?.sourceLanguage == language ? priorPartial?.target : nil
            if priorPartial != nil, carried == nil {
                DiagnosticLog.shared.info("stt", "carryover_dropped_direction_changed", [
                    "seq": message.seq,
                    "was": priorPartial?.sourceLanguage.rawValue ?? "?",
                    "now": language.rawValue,
                ])
            }
            // Moved past the hypothesis; drop this channel's gray line only —
            // the other channel's speaker may still be mid-sentence.
            partials.removeAll { Self.band($0.id) == Self.band(message.seq) }
            if lastPartialID == message.seq { lastPartialID = partials.last?.id }
            // A final arrives when the utterance *ends*; backdate by its
            // duration so a row sorts by when the speaker actually started.
            let start = date.addingTimeInterval(-Double(message.duration ?? 0) / 1000)
            var utterance = Utterance(
                id: message.seq, timestamp: start,
                sourceLanguage: language, sourceText: text, sourceState: .draft)
            if let carried, !carried.isEmpty {
                utterance.target = carried
                utterance.targetText = carried.rendered
            }
            let index = utterances.lastIndex(where: { $0.timestamp <= start })
                .map { $0 + 1 } ?? 0
            utterances.insert(utterance, at: index)
            // Rebuild the lookup map for all elements from index onward
            // since their positions shifted.
            for i in index..<utterances.count {
                indexByID[utterances[i].id] = i
            }
            newestFinalizedID = message.seq
            onFinalized?(utterance)
        } else if let idx = partials.firstIndex(where: { $0.id == message.seq }) {
            if partials[idx].sourceLanguage != language {
                // Direction flipped mid-hypothesis. Everything committed so far was
                // agreed upon in the other direction and is not evidence about this
                // one — keeping the frontier rendered words that never achieved
                // consensus as settled. Clearing both fields also stops the old
                // language's text lingering in the column it no longer belongs to.
                partials[idx].target.restart()
                partials[idx].korean = ""
                partials[idx].english = ""
                partials[idx].sourceLanguage = language
            }
            partials[idx].sourceText = text
            lastPartialID = message.seq
            onPartialUpdated?(partials[idx])
        } else if let idx = partials.firstIndex(where: { Self.band($0.id) == Self.band(message.seq) }) {
            // New hypothesis on a channel that already had one: replace ITS entry
            // only. Replacing the whole array — the original behaviour — meant that
            // in dual mode the mic channel and the call channel wiped each other's
            // live hypothesis on every update, so neither speaker's in-flight
            // sentence stayed on screen.
            partials[idx] = Utterance(
                id: message.seq, timestamp: date,
                sourceLanguage: language, sourceText: text, sourceState: .hypothesis)
            lastPartialID = message.seq
            onPartialUpdated?(partials[idx])
        } else {
            partials.append(Utterance(
                id: message.seq, timestamp: date,
                sourceLanguage: language, sourceText: text, sourceState: .hypothesis))
            lastPartialID = message.seq
            onPartialUpdated?(partials[partials.count - 1])
        }
    }

    // MARK: - Speculative translation of the live hypothesis

    /// Stream tokens into the hypothesis line's translation. No consensus — see
    /// `SpeculativeText.applyStreaming`.
    func streamPartialTranslation(seq: Int, text: String) {
        guard let idx = partials.firstIndex(where: { $0.id == seq }) else { return }
        // The skip sentinel must never reach the screen. The pipeline checks for
        // filler only *after* a pass completes, but tokens are written as they
        // arrive — so a pass answering "∅" streamed that character into the live row
        // and, because the completion path then skipped the consensus apply, it
        // stayed there. A bare ∅ was rendered to the room as the translation.
        //
        // `isSentinel`, not `isFiller`: the full check runs refusal analysis over the
        // whole string and cost ~74 µs per token. See `TranslationFilter.isSentinel`.
        guard !TranslationFilter.isSentinel(text) else { return }
        // One assignment, not two. Mutating `target` and then `targetText` through the
        // subscript is two writes to `partials`, and @Observable invalidates observers
        // per write — so every token asked SwiftUI to rebuild twice.
        var updated = partials[idx]
        updated.target.applyStreaming(text: text)
        updated.targetText = updated.target.rendered
        partials[idx] = updated
    }

    /// A speculative pass came back unusable: stop rendering it, keeping whatever
    /// earlier revisions had already committed. See `revertToLastRevision`.
    func discardPartialStream(seq: Int) {
        guard let idx = partials.firstIndex(where: { $0.id == seq }) else { return }
        var updated = partials[idx]
        updated.target.revertToLastRevision()
        updated.targetText = updated.target.rendered
        partials[idx] = updated
    }

    /// A speculative pass over the hypothesis completed: run consensus. Returns
    /// false when the revision was stale and was ignored.
    @discardableResult
    func applyPartialSpeculative(seq: Int, revision: Int, text: String) -> Bool {
        guard let idx = partials.firstIndex(where: { $0.id == seq }) else { return false }
        let accepted = partials[idx].target.apply(revision: revision, text: text)
        if accepted { partials[idx].targetText = partials[idx].target.rendered }
        return accepted
    }

    /// Stream tokens into a finalized utterance's translation, without advancing
    /// the commit frontier.
    func streamTranslation(id: Int, text: String) {
        guard let idx = indexByID[id] else { return }
        // Same guard as the partial path: a mid-stream ∅ is a skip in progress, not
        // content, and must never be rendered. `isSentinel` for the same reason.
        guard !TranslationFilter.isSentinel(text) else { return }
        var updated = utterances[idx]
        updated.target.applyStreaming(text: text)
        updated.targetText = updated.target.rendered
        utterances[idx] = updated
    }

    /// Id of the hypothesis that changed most recently. With one partial per
    /// channel, array order no longer implies recency.
    private(set) var lastPartialID: Int?

    /// The live hypothesis — what the Presentation window shows on the source side
    /// before an engine locks the sentence. The most recently *updated* one, since
    /// in dual mode two channels each keep their own.
    var currentPartial: Utterance? {
        if let id = lastPartialID, let match = partials.first(where: { $0.id == id }) {
            return match
        }
        return partials.last
    }

    /// Channel id band. Each channel's utterance ids live 1M apart
    /// (`PipelineController.channelIDStride`) so two streams can't collide, which
    /// also makes the band a reliable channel identifier here.
    private static func band(_ id: Int) -> Int { id / 1_000_000 }

    // MARK: - Arbitration

    /// Replace an utterance's source transcript after the arbiter ruled.
    ///
    /// Only called when the winning candidate differs from the draft that was
    /// already shown; the pipeline skips the call otherwise so the UI doesn't
    /// churn on a no-op. Changing `sourceLanguage` moves the text between the
    /// `korean` and `english` fields, so it is set before the text.
    func applyArbitration(id: Int, text: String, language: Language) {
        guard let idx = indexByID[id] else { return }
        if utterances[idx].sourceLanguage != language {
            // Direction flipped: clear the old field so the previous transcript
            // doesn't linger in the column it no longer belongs to.
            utterances[idx].korean = ""
            utterances[idx].english = ""
            utterances[idx].sourceLanguage = language
        }
        utterances[idx].sourceText = text
        utterances[idx].sourceState = .arbitrated
    }

    /// Mark the source final without changing it — the arbiter agreed with the
    /// draft.
    func confirmSource(id: Int) {
        guard let idx = indexByID[id] else { return }
        utterances[idx].sourceState = .arbitrated
    }

    // MARK: - Translation updates

    /// Apply a speculative revision. Returns false when the revision was stale
    /// (a slower earlier request landing late) and was therefore ignored.
    @discardableResult
    func applySpeculative(id: Int, revision: Int, text: String) -> Bool {
        guard let idx = indexByID[id] else { return false }
        let accepted = utterances[idx].target.apply(revision: revision, text: text)
        if accepted { utterances[idx].targetText = utterances[idx].target.rendered }
        return accepted
    }

    /// Final translation pass: commit everything and stop accepting revisions.
    func settleTranslation(id: Int, text: String) {
        guard let idx = indexByID[id] else { return }
        utterances[idx].target.settle(text: text)
        utterances[idx].targetText = utterances[idx].target.rendered
        utterances[idx].translationFailed = false
    }

    /// Discard everything streamed so far, INCLUDING the commit frontier.
    ///
    /// Only for the forced retry after a wrongly-emitted ∅: that pass is
    /// translating the same source again from scratch, so nothing previously
    /// committed can be trusted. The *first* final pass must NOT call this — it
    /// would throw away the words committed while the sentence was still a
    /// hypothesis, which is exactly the flicker prefix consensus exists to
    /// prevent. Use `beginTranslationPass` for that.
    func restartTranslation(id: Int) {
        guard let idx = indexByID[id] else { return }
        utterances[idx].target.restart()
        utterances[idx].targetText = ""
        utterances[idx].translationFailed = false
    }

    /// Begin a translation pass while KEEPING the commit frontier, so words
    /// committed during the hypothesis stay committed as the final pass streams.
    func beginTranslationPass(id: Int) {
        guard let idx = indexByID[id] else { return }
        utterances[idx].translationFailed = false
    }

    func failTranslation(id: Int) {
        guard let idx = indexByID[id] else { return }
        utterances[idx].translationFailed = true
        // Only *settled* text may reach transcript.md, events.jsonl or the cloud.
        // The `isEmpty` check alone was defeated by the carried-over speculative
        // translation: a failed request left that unsettled guess in place, and it
        // then exported as though it were the finished translation of the line.
        if !utterances[idx].target.settled {
            utterances[idx].target.restart()
            utterances[idx].targetText = "[translation failed]"
        }
    }

    /// Filler/noise utterance: keep the source row, drop whatever the model
    /// streamed (e.g. the ∅ sentinel), and show no translation. Empty target
    /// text also keeps the row out of `contextPairs`, so filler never pollutes
    /// the rolling translation context.
    func clearTranslation(id: Int) {
        guard let idx = indexByID[id] else { return }
        utterances[idx].target.clear()
        utterances[idx].targetText = ""
        utterances[idx].translationFailed = false
    }

    /// Last `limit` fully translated pairs preceding `id`, oldest first — the
    /// rolling context window for the translator.
    ///
    /// `source` orients the pairs: a KO→EN request needs Korean as the user turn
    /// and English as the assistant turn, an EN→KO request the reverse. Feeding
    /// a model context in the wrong direction teaches it to translate backwards.
    ///
    /// Positional, not id-ordered: per-channel seq namespacing makes ids
    /// incomparable across streams, while array order is chronological.
    func contextPairs(before id: Int, from source: Language, limit: Int = 10) -> [TranslationPair] {
        let end = indexByID[id] ?? utterances.count
        // Walk back from `end` and stop as soon as `limit` translated utterances have
        // been collected, instead of filtering the whole meeting and discarding all
        // but the last few. Speculation issues many translation requests per
        // utterance, so this ran often enough for its O(N) scan to matter: it measured
        // 105 µs at 500 utterances against 9 µs at 20.
        //
        // Equivalent to the original by construction: the same predicate, the same
        // last-`limit` window, and the empty-pair filter still applied AFTER the
        // window is chosen — so a pair dropped for being empty still consumes one of
        // the `limit` slots exactly as it did before.
        var window: [Utterance] = []
        window.reserveCapacity(limit)
        var index = end - 1
        while index >= 0, window.count < limit {
            let utterance = utterances[index]
            index -= 1
            guard utterance.state == .translated, !utterance.targetText.isEmpty else { continue }
            window.append(utterance)
        }
        return window
            .reversed()
            .map { utterance in
                // Orient each pair to the *requested* direction, not the
                // direction the historical utterance happened to be spoken in.
                source == .ko
                    ? TranslationPair(source: utterance.korean, target: utterance.english)
                    : TranslationPair(source: utterance.english, target: utterance.korean)
            }
            .filter { !$0.source.isEmpty && !$0.target.isEmpty }
    }

    // MARK: - Session

    func startSession() {
        utterances = []
        partials = []
        indexByID = [:]
        newestFinalizedID = nil
        lastPartialID = nil
        sessionStart = Date()
    }

    // MARK: - Export

    /// Markdown export: timestamp / KO / EN per block. The direction marker
    /// records who was speaking which language, which a bilingual transcript
    /// otherwise loses.
    func exportMarkdown() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"

        var out = "# Transcript — \(df.string(from: sessionStart ?? Date()))\n"
        for u in utterances {
            let marker = u.sourceLanguage == .ko ? "KO" : "EN"
            out += "\n**\(tf.string(from: u.timestamp))** · \(marker)\n"
            if !u.korean.isEmpty { out += "\(u.korean)\n" }
            if !u.english.isEmpty { out += "> \(u.english)\n" }
        }
        return out
    }

    @discardableResult
    func exportToDownloads() throws -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HHmm"
        let name = "Transcript \(df.string(from: sessionStart ?? Date())).md"
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        try exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
