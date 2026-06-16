import Foundation

enum UtteranceState: Equatable {
    case partial      // mutating hypothesis, not yet locked by RTZR
    case finalized    // Korean locked, translation not yet started
    case translating  // English streaming in
    case translated   // complete row
    case failed       // translation failed
}

/// One row of the transcript. `id` is the (reconnect-adjusted) RTZR seq.
struct Utterance: Identifiable, Equatable {
    let id: Int
    let timestamp: Date
    var korean: String
    var english: String = ""
    var state: UtteranceState
}

/// A finished (Korean, English) pair used as rolling conversation context
/// for the translator.
struct TranslationPair: Equatable {
    let korean: String
    let english: String
}
