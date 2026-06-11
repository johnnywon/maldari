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
}
