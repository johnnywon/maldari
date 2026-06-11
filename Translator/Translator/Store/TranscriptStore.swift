import Foundation

/// Single source of truth for the live transcript. RTZR messages flow in via
/// `apply(_:)`; the UI observes `utterances` + `partial`; finalized utterances
/// are handed to `onFinalized` so the pipeline can enqueue translation.
@MainActor
@Observable
final class TranscriptStore {
    private(set) var utterances: [Utterance] = []
    /// The current mutating hypotheses, rendered as gray lines pinned at the
    /// bottom of the transcript — at most one per capture channel (speaker),
    /// so dual-capture sessions can show "Me" and "Them" talking over each
    /// other. Each mutates in place per seq.
    private(set) var partials: [Utterance] = []

    var sessionStart: Date?

    /// Fired when RTZR locks an utterance (final=true, non-empty text).
    var onFinalized: ((Utterance) -> Void)?

    // MARK: - STT ingestion

    func apply(_ message: STTMessage, speaker: Speaker? = nil, at date: Date = Date()) {
        guard let text = message.bestText else {
            // Empty hypothesis: a final with no text just clears its partial.
            if message.isFinal {
                partials.removeAll { $0.speaker == speaker && $0.id == message.seq }
            }
            return
        }

        if message.isFinal {
            // The channel moved past its hypothesis; drop it even if seqs
            // disagree, or a stale gray line lingers forever.
            partials.removeAll { $0.speaker == speaker }
            // A final arrives when the utterance *ends*; backdate by its
            // duration so rows from concurrent channels merge in the order
            // people actually started talking.
            let start = date.addingTimeInterval(-Double(message.duration ?? 0) / 1000)
            let utterance = Utterance(
                id: message.seq, timestamp: start, korean: text, state: .finalized,
                speaker: speaker)
            // Guard against duplicate finals for the same seq.
            guard !utterances.contains(where: { $0.id == message.seq }) else { return }
            let index = utterances.lastIndex(where: { $0.timestamp <= start })
                .map { $0 + 1 } ?? 0
            utterances.insert(utterance, at: index)
            onFinalized?(utterance)
        } else if let idx = partials.firstIndex(where: { $0.speaker == speaker }) {
            if partials[idx].id == message.seq {
                partials[idx].korean = text
            } else {
                partials[idx] = Utterance(
                    id: message.seq, timestamp: date, korean: text, state: .partial,
                    speaker: speaker)
            }
        } else {
            partials.append(Utterance(
                id: message.seq, timestamp: date, korean: text, state: .partial,
                speaker: speaker))
        }
    }

    // MARK: - Translation updates

    func beginTranslation(id: Int) {
        guard let idx = utterances.firstIndex(where: { $0.id == id }) else { return }
        utterances[idx].english = ""
        utterances[idx].state = .translating
    }

    func appendTranslation(id: Int, token: String) {
        guard let idx = utterances.firstIndex(where: { $0.id == id }) else { return }
        utterances[idx].english += token
    }

    func endTranslation(id: Int, failed: Bool = false) {
        guard let idx = utterances.firstIndex(where: { $0.id == id }) else { return }
        utterances[idx].state = failed ? .failed : .translated
        if failed && utterances[idx].english.isEmpty {
            utterances[idx].english = "[translation failed]"
        }
    }

    /// Filler/noise utterance: keep the Korean row, drop whatever the model
    /// streamed (e.g. the ∅ sentinel), and show no English line. Empty
    /// english also keeps the row out of `contextPairs`, so filler never
    /// pollutes the rolling translation context.
    func clearTranslation(id: Int) {
        guard let idx = utterances.firstIndex(where: { $0.id == id }) else { return }
        utterances[idx].english = ""
        utterances[idx].state = .translated
    }

    /// Last `limit` fully translated pairs preceding `id`, oldest first —
    /// the rolling context window for the translator. Positional, not
    /// id-ordered: per-channel seq namespacing makes ids incomparable across
    /// streams, while array order is chronological.
    func contextPairs(before id: Int, limit: Int = 10) -> [TranslationPair] {
        let end = utterances.firstIndex(where: { $0.id == id }) ?? utterances.count
        return utterances[..<end]
            .filter { $0.state == .translated && !$0.english.isEmpty }
            .suffix(limit)
            .map { TranslationPair(korean: $0.korean, english: $0.english) }
    }

    // MARK: - Session

    func startSession() {
        utterances = []
        partials = []
        sessionStart = Date()
    }

    // MARK: - Export

    /// Markdown export: timestamp / KO / EN per block.
    func exportMarkdown() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"

        var out = "# Transcript — \(df.string(from: sessionStart ?? Date()))\n"
        for u in utterances {
            let speakerSuffix = u.speaker.map { " — \($0.label)" } ?? ""
            out += "\n**\(tf.string(from: u.timestamp))\(speakerSuffix)**\n"
            out += "\(u.korean)\n"
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
