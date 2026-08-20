import Foundation

/// How far the *source* transcript of an utterance has progressed.
enum SourceState: Equatable, Sendable {
    /// Mutating STT hypothesis, not yet locked by any engine.
    case hypothesis
    /// One engine locked the utterance; the arbiter has not ruled yet.
    case draft
    /// Arbitration complete — this is the transcript of record.
    case arbitrated
}

/// Coarse row state the views and diagnostics read. **Derived**, not stored:
/// with speculative translation there is no single moment that is "translating",
/// so it is computed from `sourceState` and the target's own progress. Nothing
/// writes it.
enum UtteranceState: Equatable {
    case partial      // mutating hypothesis, not yet locked
    case finalized    // source locked, translation not yet started
    case translating  // translation streaming / being revised
    case translated   // complete row
    case failed       // translation failed
}

/// One row of the transcript. `id` is the (reconnect- and channel-adjusted) seq.
///
/// **Korean always lives in `korean` and English always in `english`, whichever
/// was spoken.** Only `sourceLanguage` records the direction. Keeping the fields
/// language-named rather than role-named means `SessionRecorder`'s JSONL,
/// `transcript.md`, the cloud payload, and the web viewer keep working
/// unchanged — and it matches how both the transcript and Presentation windows
/// render: Korean first, English second, always.
struct Utterance: Identifiable, Equatable {
    let id: Int
    let timestamp: Date
    var korean: String = ""
    var english: String = ""

    /// Which language was actually spoken. Drives the accent colour and which
    /// of the two fields is the transcript vs the translation.
    var sourceLanguage: Language = .ko
    var sourceState: SourceState = .hypothesis

    /// Progressive translation. `targetText` mirrors its rendered form so the
    /// language-named fields stay authoritative for persistence and export.
    var target = SpeculativeText()

    /// Set when the translation request errored. Kept separate from
    /// `target.settled` so a failure is distinguishable from an empty result.
    var translationFailed = false

    // MARK: - Direction-aware accessors

    /// The transcript of what was actually said.
    var sourceText: String {
        get { sourceLanguage == .ko ? korean : english }
        set {
            if sourceLanguage == .ko { korean = newValue } else { english = newValue }
        }
    }

    /// The translation of what was said.
    var targetText: String {
        get { sourceLanguage == .ko ? english : korean }
        set {
            if sourceLanguage == .ko { english = newValue } else { korean = newValue }
        }
    }

    var targetLanguage: Language { sourceLanguage.other }

    // MARK: - Derived state

    var state: UtteranceState {
        if translationFailed { return .failed }
        if sourceState == .hypothesis { return .partial }
        if !target.hasStarted { return .finalized }
        return target.settled ? .translated : .translating
    }

    // MARK: - Init

    init(
        id: Int,
        timestamp: Date,
        sourceLanguage: Language = .ko,
        sourceText: String = "",
        sourceState: SourceState = .hypothesis
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceLanguage = sourceLanguage
        self.sourceState = sourceState
        if sourceLanguage == .ko { self.korean = sourceText } else { self.english = sourceText }
    }
}

/// A finished (source, target) pair used as rolling conversation context for the
/// translator. Role-named rather than language-named because context must be
/// presented in the direction of the request being made: a KO→EN call needs
/// Korean as the user turn, an EN→KO call needs English.
struct TranslationPair: Equatable {
    let source: String
    let target: String
}
