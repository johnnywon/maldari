import Foundation

/// The two languages the app bridges. `rawValue` is the code written to
/// diagnostics, session recordings, and the cloud payload.
enum Language: String, Codable, Equatable, Sendable, CaseIterable {
    case ko
    case en

    var other: Language { self == .ko ? .en : .ko }

    var displayName: String {
        switch self {
        case .ko: return "Korean"
        case .en: return "English"
        }
    }
}

/// Cheap, network-free language identification by writing system.
///
/// This is tier 1 of the transcript arbiter. While STT hypotheses are still
/// mutating we need a per-frame answer with no round trip and no model, and
/// "which script is this written in" answers it for Korean vs English
/// specifically: Hangul and Latin don't overlap, so the ratio is decisive in a
/// way it would not be for, say, Japanese vs Chinese.
enum ScriptDetector {

    /// Fraction of letter-bearing scalars that are Hangul, 0...1.
    ///
    /// Digits, punctuation, and whitespace are deliberately ignored. "12" is
    /// neither Korean nor English, and counting such characters would drag a
    /// short numeric utterance toward whichever side happened to carry more
    /// padding. Returns nil when there are no letters at all to judge.
    static func hangulFraction(_ text: String) -> Double? {
        var hangul = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isHangul(scalar) {
                hangul += 1
            } else if isLatinLetter(scalar) {
                latin += 1
            }
        }
        let total = hangul + latin
        guard total > 0 else { return nil }
        return Double(hangul) / Double(total)
    }

    /// The language a transcript is written in, or nil when undecidable
    /// (no letters at all — "123", "…", "").
    ///
    /// RTZR transcribing English audio emits Hangul romanization, so a low
    /// Hangul fraction from RTZR is itself the signal that the wrong engine is
    /// listening — see `TranscriptArbiter`.
    static func language(of text: String, threshold: Double = 0.5) -> Language? {
        guard let fraction = hangulFraction(text) else { return nil }
        return fraction >= threshold ? .ko : .en
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0xAC00...0xD7A3).contains(v)   // precomposed syllables
            || (0x1100...0x11FF).contains(v)   // jamo
            || (0x3130...0x318F).contains(v)   // compatibility jamo
            || (0xA960...0xA97F).contains(v)   // jamo extended-A
            || (0xD7B0...0xD7FF).contains(v)   // jamo extended-B
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x41...0x5A).contains(v)       // A-Z
            || (0x61...0x7A).contains(v)       // a-z
            || (0xC0...0x24F).contains(v)      // Latin-1 supplement + extended-A/B
    }
}
