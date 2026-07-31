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

    // MARK: - STT ingestion

    func apply(_ message: STTMessage, at date: Date = Date()) {
        guard let text = message.bestText else {
            // Empty hypothesis: a final with no text just clears the partial.
            if message.isFinal { partials.removeAll() }
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
            let carried = partials.first { $0.id == message.seq }?.target
            // Moved past the hypothesis; drop the gray line.
            partials.removeAll()
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
            onFinalized?(utterance)
        } else if let idx = partials.firstIndex(where: { $0.id == message.seq }) {
            partials[idx].sourceLanguage = language
            partials[idx].sourceText = text
            onPartialUpdated?(partials[idx])
        } else {
            // New hypothesis seq → replace the single pinned partial line.
            partials = [Utterance(
                id: message.seq, timestamp: date,
                sourceLanguage: language, sourceText: text, sourceState: .hypothesis)]
            onPartialUpdated?(partials[0])
        }
    }

    // MARK: - Speculative translation of the live hypothesis

    /// Stream tokens into the hypothesis line's translation. No consensus — see
    /// `SpeculativeText.applyStreaming`.
    func streamPartialTranslation(seq: Int, text: String) {
        guard let idx = partials.firstIndex(where: { $0.id == seq }) else { return }
        partials[idx].target.applyStreaming(text: text)
        partials[idx].targetText = partials[idx].target.rendered
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
        utterances[idx].target.applyStreaming(text: text)
        utterances[idx].targetText = utterances[idx].target.rendered
    }

    /// The live hypothesis, if any — what the Presentation window shows on the
    /// source side before an engine locks the sentence.
    var currentPartial: Utterance? { partials.last }

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
        if utterances[idx].target.isEmpty {
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
        return utterances[..<end]
            .filter { $0.state == .translated && !$0.targetText.isEmpty }
            .suffix(limit)
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
