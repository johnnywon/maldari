import Foundation

/// Which speech engine produced a transcript. Both run on the same audio in
/// bidirectional modes, and the arbiter picks a winner per utterance.
enum STTEngine: String, Equatable, Sendable, CaseIterable {
    /// RTZR sommers_ko — Korean specialist, keyword boosting, business-tuned.
    case rtzr
    /// OpenAI Realtime — multilingual generalist. Needs a paid OpenAI key.
    case openai

    /// The language this engine is authoritative for.
    var nativeLanguage: Language? {
        switch self {
        case .rtzr: return .ko
        case .openai: return nil    // no home turf; it handles both
        }
    }

    var displayName: String {
        switch self {
        case .rtzr: return "RTZR (Korean)"
        case .openai: return "OpenAI Realtime"
        }
    }
}

/// One transcript message from a streaming STT engine.
///
/// The wire shape is RTZR's (developers.rtzr.ai, Streaming STT → WebSocket):
/// { "seq": 0, "start_at": 1234, "duration": 980, "final": false,
///   "alternatives": [{ "text": "...", "confidence": 0.97 }] }
///
/// `OpenAIRealtimeSTTService` builds the same struct by hand rather than
/// decoding into it, so the pipeline has one message type regardless of engine.
struct STTMessage: Decodable, Equatable {
    var seq: Int
    let startAt: Int?
    let duration: Int?
    let isFinal: Bool
    let alternatives: [Alternative]

    /// Which engine produced this. Not part of any wire format — the service
    /// stamps it so the arbiter can tell candidates apart.
    var engine: STTEngine = .rtzr

    /// Language the engine reported, when it reports one. RTZR never does (it
    /// only runs sommers_ko); OpenAI Realtime may. nil means "infer from the
    /// text" — see `ScriptDetector`.
    var language: Language?

    struct Alternative: Decodable, Equatable {
        let text: String
        let confidence: Double?
    }

    /// `engine` and `language` are omitted deliberately: they are not in the
    /// wire format, and both carry defaults so Decodable synthesis still works.
    enum CodingKeys: String, CodingKey {
        case seq
        case startAt = "start_at"
        case duration
        case isFinal = "final"
        case alternatives
    }

    /// Top hypothesis text, trimmed. Nil when the engine sends an empty
    /// alternative.
    var bestText: String? {
        guard let text = alternatives.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    var confidence: Double? { alternatives.first?.confidence }

    /// The language this message is in: what the engine said, else what the
    /// writing system implies.
    var resolvedLanguage: Language? {
        language ?? bestText.flatMap { ScriptDetector.language(of: $0) }
    }

    static func decode(_ data: Data) throws -> STTMessage {
        try JSONDecoder().decode(STTMessage.self, from: data)
    }

    /// Build a message directly — used by non-RTZR engines and by tests.
    init(
        seq: Int,
        startAt: Int? = nil,
        duration: Int? = nil,
        isFinal: Bool,
        text: String,
        confidence: Double? = nil,
        engine: STTEngine = .rtzr,
        language: Language? = nil
    ) {
        self.seq = seq
        self.startAt = startAt
        self.duration = duration
        self.isFinal = isFinal
        self.alternatives = [Alternative(text: text, confidence: confidence)]
        self.engine = engine
        self.language = language
    }
}
