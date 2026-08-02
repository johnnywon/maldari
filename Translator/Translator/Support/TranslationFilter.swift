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
    /// an empty result, a legacy wholly-bracketed placeholder like
    /// "(no output - filler/incomplete thought)", or a conversational refusal.
    static func isFiller(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == sentinel { return true }
        if isRefusal(text) { return true }

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

    /// True when the model answered the *user* instead of translating.
    ///
    /// Observed in a real meeting: a Korean-only recognizer transcribed English
    /// speech as Hangul syllable salad, and the translator — which had no rule for
    /// unintelligible input — replied "I'm unable to parse that input with
    /// confidence. Could you please repeat or clarify what you said?". That plea
    /// was rendered on the guest-facing screen as though it were what the speaker
    /// had said, and written to transcript.md, events.jsonl and the cloud.
    ///
    /// The prompt now forbids this explicitly; this is the deterministic backstop,
    /// because one stray refusal on a meeting-room display is unrecoverable.
    ///
    /// **Both a meta-reference AND an inability marker are required.** Either alone
    /// gives false positives on real translations: "Could you please repeat that?"
    /// is the correct rendering of 다시 말씀해 주시겠어요?, and "we can't meet that
    /// unit price" is a perfectly ordinary sentence. Only text that expresses
    /// inability *about the input itself* is a refusal.
    static func isRefusal(_ raw: String) -> Bool {
        let lower = raw.lowercased()

        // Refers to the transcript/input rather than to the meeting's subject.
        // Deliberately excludes "the audio": "the audio on their end is garbled, can
        // you hear them?" is an ordinary thing to say in a video call, and pairing
        // that phrase with the inability list below flagged it as a refusal. The
        // surviving markers all name the *transcript* rather than the meeting.
        let metaMarkers = [
            "input", "parse", "transcript", "transcription", "the text", "this text",
            "what you said", "gibberish", "nonsens",
            "unintelligible", "not korean", "not english",
            // Korean side, for the EN→KO direction.
            "입력", "텍스트", "말씀하신 내용", "판독",
        ]
        // Expresses inability or non-comprehension.
        //
        // The predicate forms ("is unintelligible") are deliberate rather than the
        // bare words: a participant saying "that spec reads like gibberish" is a
        // real sentence that must survive, while "the input is gibberish" is not.
        let inabilityMarkers = [
            "unable to", "not able to", "cannot", "can't", "could not", "couldn't",
            "don't understand", "do not understand", "unclear", "not clear",
            "no discernible", "does not make sense", "doesn't make sense",
            "appears to be", "seems to be",
            "is unintelligible", "was unintelligible", "is gibberish",
            "is garbled", "is nonsensical", "cannot be transcribed",
            // Korean. Deliberately NOT 어렵습니다 — "단가를 맞추기 어렵습니다"
            // ("we can't meet that unit price") is ordinary business Korean and
            // would be destroyed by matching it.
            "이해할 수 없", "알아들을 수 없", "판독할 수 없", "확인할 수 없",
        ]

        let hasMeta = metaMarkers.contains { lower.contains($0) }
        guard hasMeta else { return false }
        return inabilityMarkers.contains { lower.contains($0) }
    }

    /// Minimum non-space character count for an utterance to be treated as
    /// "clearly carrying content". Genuine filler/backchannels (어, 음, 그, 응,
    /// 으흠, 네네) are at most a few syllables; real sentences run far longer.
    /// Diagnostics from real meetings showed a clean gap: dropped-but-real
    /// lines were 40+ chars, genuine filler ≤7.
    static let substanceThreshold = 8

    /// True when the source clearly carries translatable content, so a ∅ from the
    /// model is almost certainly a mistake. Real-time STT of natural speech is
    /// disfluent and the model over-applies the skip rule; this is the
    /// deterministic backstop that catches it. Length-based on purpose: cheap,
    /// predictable, and the false-positive cost (one wasted retry on a long
    /// stretch of pure filler) is far lower than the false-negative cost (a real
    /// sentence silently vanishing from the transcript).
    ///
    /// The same character threshold serves both directions even though English
    /// is less dense than Korean: 8 non-space characters is still below any real
    /// English sentence ("okay" and "got it" are 4 and 5), so the gap holds.
    static func sourceHasSubstance(_ text: String) -> Bool {
        text.filter { !$0.isWhitespace }.count >= substanceThreshold
    }

    /// Kept as the original name so existing call sites and tests keep reading
    /// naturally; the rule is language-agnostic.
    static func koreanHasSubstance(_ korean: String) -> Bool {
        sourceHasSubstance(korean)
    }
}
