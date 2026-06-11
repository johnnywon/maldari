import Foundation

/// One JSON message from the RTZR streaming WebSocket.
/// Shape (verified against developers.rtzr.ai, Streaming STT → WebSocket):
/// { "seq": 0, "start_at": 1234, "duration": 980, "final": false,
///   "alternatives": [{ "text": "...", "confidence": 0.97 }] }
struct STTMessage: Decodable, Equatable {
    var seq: Int
    let startAt: Int?
    let duration: Int?
    let isFinal: Bool
    let alternatives: [Alternative]

    struct Alternative: Decodable, Equatable {
        let text: String
        let confidence: Double?
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case startAt = "start_at"
        case duration
        case isFinal = "final"
        case alternatives
    }

    /// Top hypothesis text, trimmed. Nil when RTZR sends an empty alternative.
    var bestText: String? {
        guard let text = alternatives.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    static func decode(_ data: Data) throws -> STTMessage {
        try JSONDecoder().decode(STTMessage.self, from: data)
    }
}
