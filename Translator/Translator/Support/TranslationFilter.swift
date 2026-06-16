import Foundation

/// Detects "no translatable content" signals from the translator so filler
/// utterances (어, 음, bare 네네, abandoned fragments) render as Korean-only
/// rows instead of leaking placeholder text into the transcript.
enum TranslationFilter {
    /// The system prompt instructs the model to emit exactly this for filler.
    /// A single concrete token is reliable; "output nothing" is not — models
    /// "output nothing" by *describing* nothing ("(no output - filler)"),
    /// and those placeholders then enter the rolling context as assistant
    /// turns, teaching the model to keep doing it.
    static let sentinel = "∅"

    /// True when the translation output means "skip this row": the sentinel,
    /// an empty result, or a legacy wholly-bracketed placeholder like
    /// "(no output - filler/incomplete thought)".
    static func isFiller(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == sentinel { return true }

        let lower = text.lowercased()
        let bracketed =
            (lower.hasPrefix("(") && lower.hasSuffix(")")) ||
            (lower.hasPrefix("[") && lower.hasSuffix("]"))
        guard bracketed else { return false }

        let inner = lower.dropFirst().dropLast()
        let markers = ["no output", "no translation", "no content", "filler",
                       "noise", "skip", "incomplete"]
        return markers.contains { inner.contains($0) }
    }

    /// Minimum non-space character count for an utterance to be treated as
    /// "clearly carrying content". Genuine filler/backchannels (어, 음, 그, 응,
    /// 으흠, 네네) are at most a few syllables; real sentences run far longer.
    /// Diagnostics from real meetings showed a clean gap: dropped-but-real
    /// lines were 40+ chars, genuine filler ≤7.
    static let substanceThreshold = 8

    /// True when the Korean source clearly carries translatable content, so a
    /// ∅ from the model is almost certainly a mistake. Real-time STT of natural
    /// speech is disfluent and the model over-applies the skip rule; this is
    /// the deterministic backstop that catches it. Length-based on purpose:
    /// cheap, predictable, and the false-positive cost (one wasted retry on a
    /// long stretch of pure filler) is far lower than the false-negative cost
    /// (a real sentence silently vanishing from the transcript).
    static func koreanHasSubstance(_ korean: String) -> Bool {
        korean.filter { !$0.isWhitespace }.count >= substanceThreshold
    }
}
