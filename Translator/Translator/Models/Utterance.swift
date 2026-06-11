import Foundation

enum UtteranceState: Equatable {
    case partial      // mutating hypothesis, not yet locked by RTZR
    case finalized    // Korean locked, translation not yet started
    case translating  // English streaming in
    case translated   // complete row
    case failed       // translation failed
}

/// Which capture channel an utterance came from. RTZR streaming STT has no
/// diarization, so attribution is per-channel: in dual-capture mode the
/// microphone is "Me" and system audio is "Them". Nil for single-channel
/// sessions, where attribution is unknowable.
enum Speaker: String, Equatable {
    case me
    case them

    var label: String {
        switch self {
        case .me: return "Me"
        case .them: return "Them"
        }
    }
}

/// One row of the transcript. `id` is the (reconnect-adjusted, per-channel
/// namespaced) RTZR seq.
struct Utterance: Identifiable, Equatable {
    let id: Int
    let timestamp: Date
    var korean: String
    var english: String = ""
    var state: UtteranceState
    var speaker: Speaker? = nil
}

/// A finished (Korean, English) pair used as rolling conversation context
/// for the translator.
struct TranslationPair: Equatable {
    let korean: String
    let english: String
}
