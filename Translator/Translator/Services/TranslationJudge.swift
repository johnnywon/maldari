import Foundation

/// Protocol seam for tier 2 of the transcript arbiter — the only tier that
/// costs a model call.
///
/// Tiers 1 and 1.5 (`ScriptDetector`, `TranscriptArbiter.decide`) are pure
/// functions over strings and settle the large majority of lines for free. The
/// judge runs only when the arbiter returns `.needsJudge(language)`: both
/// engines agree on the language but disagree materially on the words.
/// Expected on roughly one line in eight.
/// The outcome of tier-2 arbitration.
///
/// Richer than the engine name it used to be, because the case that motivated all of
/// this — a Korean-only recognizer transcribing English speech as Hangul — requires
/// correcting the LANGUAGE, not just choosing between two transcripts. A judge that
/// can only name a winner cannot express "both of you heard Korean, but this was
/// actually English".
struct JudgeVerdict: Equatable, Sendable {
    let engine: STTEngine
    /// Corrected transcript, or nil to use the winning candidate's own text.
    let text: String?
    /// Corrected language, or nil to keep the winning candidate's.
    let language: Language?
    /// The winner's own calibrated confidence, 0...1. The caller refuses to
    /// overwrite what is already on screen below its own threshold — the user's
    /// requirement was that the winning side be *convinced* of its accuracy.
    let confidence: Double
    let reasoning: String

    init(engine: STTEngine, text: String? = nil, language: Language? = nil,
         confidence: Double, reasoning: String = "") {
        self.engine = engine
        self.text = text
        self.language = language
        self.confidence = min(max(confidence, 0), 1)
        self.reasoning = reasoning
    }
}

protocol TranscriptJudging: AnyObject {
    /// Returns a verdict, or nil to abstain — in which case the caller keeps its
    /// cheap deterministic pick. Abstaining is a normal outcome, not a failure.
    func judge(candidates: [TranscriptArbiter.Candidate],
               language: Language,
               context: [String]) async -> JudgeVerdict?
}

final class NoopTranscriptJudge: TranscriptJudging {
    func judge(candidates: [TranscriptArbiter.Candidate],
               language: Language,
               context: [String]) async -> JudgeVerdict? {
        nil
    }
}

/// Claude Haiku transcript judge. Raw Messages API, non-streaming, no SDK.
///
/// Non-streaming on purpose: the whole answer is a single letter, so SSE would
/// add framing and parsing for nothing. The reply is capped at a handful of
/// tokens, which also bounds the worst case if the model ignores the
/// output rule and starts explaining itself.
///
/// **This class never throws and never fails an utterance.** Every error —
/// missing key, HTTP failure, garbled reply, timeout, cancellation — is
/// swallowed into nil and logged. A judge that errors would take a good
/// transcript down with it; a judge that abstains just leaves the arbiter's
/// cheap pick standing.
final class ClaudeTranscriptJudge: TranscriptJudging {

    /// Reuses the translator's model deliberately: the judge is a cheap
    /// side-call on the same account, and pinning it to one model keeps
    /// per-meeting cost predictable.
    static let model = ClaudeTranslationService.model

    /// HARD ceiling on the whole request, wall clock.
    ///
    /// This call sits between a sentence being spoken and its correction
    /// appearing on a guest-facing screen. A judge that answers in 300 ms
    /// buys a better transcript; a judge that answers in three seconds
    /// rewrites a line the room has already moved past, which reads as a
    /// glitch. A slow judge is worse than no judge, so on timeout we abstain
    /// and the caller keeps the cheap pick.
    static let timeout: TimeInterval = 1.2

    /// One letter is one token. The slack is for a stray space or newline.
    static let maxTokens = 8

    /// How many finalized lines of context to send. Enough to establish who
    /// is talking about what; short enough that the prompt stays small.
    static let contextLines = 3

    /// Context lines are trimmed — a runaway earlier line must not push this
    /// request's latency past the budget above.
    private static let maxContextChars = 200

    /// Diagnostics only. Full transcripts live in the session recording; the
    /// log just needs enough to identify which line was judged.
    private static let logTextChars = 80

    /// The judging rules, in a static constant so the bytes are stable across
    /// every call in a meeting.
    ///
    /// Byte-stability is the point. Anthropic prompt caching keys on the exact
    /// system block, so an interpolated value here (a timestamp, the language,
    /// a candidate) would defeat it on every request — everything that varies
    /// goes in the user turn instead. Note this prompt is well under Haiku's
    /// minimum cacheable prefix, so today it creates no cache entry and
    /// `cache_control` below is a no-op; the constant keeps that free if the
    /// rules ever grow past the threshold.
    static let systemPrompt = """
        Two speech-recognition engines transcribed the same short passage of \
        live meeting audio and disagree about the words. Decide which \
        transcript is the more plausible record of what was actually said.

        JUDGE ON:
        - Fluency: does it read like a sentence a person would actually speak \
        in this language, including the normal disfluency of real speech?
        - Coherence of proper nouns, product names, and numbers. A garbled \
        company name or an implausible figure is a mis-hearing.
        - Obvious mis-hearings: a phonetically similar word that makes the \
        sentence nonsense, a dropped negation, a word doubled where the \
        speaker said it once.
        - Continuity with the preceding lines of the meeting, when provided.

        DO NOT judge which is better writing. Punctuation, capitalization, \
        formatting, politeness, and concision are irrelevant here. The more \
        faithful transcript wins even when it is the messier one.

        OUTPUT: exactly one character, the letter of the better option. No \
        punctuation, no explanation, no quotation marks.
        """

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Both timeouts are set to the same value, and both are needed: the
    /// request timeout is a per-byte idle gap, so a connection that trickles
    /// bytes would never trip it. `timeoutIntervalForResource` is what
    /// actually guarantees the 1.2s wall-clock ceiling.
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = ClaudeTranscriptJudge.timeout
        config.timeoutIntervalForResource = ClaudeTranscriptJudge.timeout
        return URLSession(configuration: config)
    }()

    private let session: URLSession

    init(session: URLSession = ClaudeTranscriptJudge.defaultSession) {
        self.session = session
    }

    // MARK: - Judging

    func judge(
        candidates: [TranscriptArbiter.Candidate],
        language: Language,
        context: [String]
    ) async -> JudgeVerdict? {
        // Fewer than two candidates is not a disagreement. Abstaining leaves
        // the caller's cheap pick — which for one candidate is that candidate —
        // rather than dressing up a non-choice as a verdict.
        guard candidates.count >= 2 else {
            DiagnosticLog.shared.info("stt", "judge_skipped", [
                "reason": "needs at least two candidates",
                "candidates": candidates.count,
            ])
            return nil
        }

        // No key means no judge, and no network call to discover that.
        guard let apiKey = Credentials.get(.anthropicAPIKey) else {
            DiagnosticLog.shared.warn("stt", "judge_failed", [
                "error": "anthropic api key not configured",
            ])
            return nil
        }

        DiagnosticLog.shared.info("stt", "judge_requested", [
            "language": language.rawValue,
            "candidates": candidates.count,
            "a_engine": candidates[0].engine.rawValue,
            "a_text": String(candidates[0].text.prefix(Self.logTextChars)),
            "b_engine": candidates[1].engine.rawValue,
            "b_text": String(candidates[1].text.prefix(Self.logTextChars)),
        ])

        let started = Date()
        func elapsedMS() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        do {
            let request = try Self.makeRequest(
                apiKey: apiKey, candidates: candidates,
                language: language, context: context)

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? ""
                DiagnosticLog.shared.error("stt", "judge_failed", [
                    "status": status,
                    "body": String(errorBody.prefix(300)),
                    "latency_ms": elapsedMS(),
                ])
                return nil
            }

            guard let reply = Self.replyText(from: data) else {
                DiagnosticLog.shared.error("stt", "judge_failed", [
                    "error": "no text block in response",
                    "latency_ms": elapsedMS(),
                ])
                return nil
            }

            // Anything unparseable abstains rather than guessing. A wrong
            // verdict swaps a good transcript for a bad one on screen; an
            // abstention just keeps the heuristic's answer.
            guard let index = Self.firstLabelIndex(in: reply),
                  candidates.indices.contains(index)
            else {
                DiagnosticLog.shared.error("stt", "judge_failed", [
                    "error": "unparseable verdict",
                    "reply": String(reply.prefix(40)),
                    "latency_ms": elapsedMS(),
                ])
                return nil
            }

            let winner = candidates[index].engine
            DiagnosticLog.shared.info("stt", "judge_decided", [
                "winner": winner.rawValue,
                "label": Self.label(for: index),
                "language": language.rawValue,
                "latency_ms": elapsedMS(),
            ])
            // This single-shot judge only picks between the transcripts it was given,
            // so it reports no text correction and no language change. Its confidence
            // is fixed at the caller's floor: a bare letter carries no calibration,
            // and inventing a high number would let it outrank a debate verdict that
            // actually measured its own certainty.
            return JudgeVerdict(
                engine: winner,
                confidence: 0.7,
                reasoning: "single-shot judge picked \(Self.label(for: index))")
        } catch let error as URLError where error.code == .timedOut {
            DiagnosticLog.shared.warn("stt", "judge_timeout", [
                "latency_ms": elapsedMS(),
                "limit_ms": Int(Self.timeout * 1000),
            ])
            return nil
        } catch let error as URLError where error.code == .cancelled {
            // The utterance moved on (a later revision superseded it, or the
            // session stopped). Expected, not a fault.
            DiagnosticLog.shared.info("stt", "judge_cancelled", [
                "latency_ms": elapsedMS(),
            ])
            return nil
        } catch {
            DiagnosticLog.shared.error("stt", "judge_failed", [
                "error": error.localizedDescription,
                "latency_ms": elapsedMS(),
            ])
            return nil
        }
    }

    // MARK: - Wire format
    //
    // Static and pure so tests can assert the exact body and the exact prompt
    // without a network stub — same shape as CloudSyncService.makeRequest.

    static func makeRequest(
        apiKey: String,
        candidates: [TranscriptArbiter.Candidate],
        language: Language,
        context: [String]
    ) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": [
                ["type": "text",
                 "text": systemPrompt,
                 "cache_control": ["type": "ephemeral"]]
            ],
            "messages": [
                ["role": "user",
                 "content": prompt(candidates: candidates,
                                   language: language,
                                   context: context)]
            ],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The user turn: context, then the candidates as labelled options.
    ///
    /// Everything that varies per call lives here rather than in the system
    /// block, so the system block stays byte-identical — see `systemPrompt`.
    static func prompt(
        candidates: [TranscriptArbiter.Candidate],
        language: Language,
        context: [String]
    ) -> String {
        var lines: [String] = []

        let recent = context.suffix(contextLines).filter { !$0.isEmpty }
        if !recent.isEmpty {
            lines.append("Preceding lines of this meeting:")
            for line in recent {
                lines.append("- " + String(line.prefix(maxContextChars)))
            }
            lines.append("")
        }

        lines.append("Spoken language: \(language.displayName)")
        lines.append("")
        for (index, candidate) in candidates.enumerated() {
            lines.append("\(label(for: index)). \(candidate.text)")
        }
        lines.append("")
        lines.append("Which is the more plausible transcription? One letter.")

        return lines.joined(separator: "\n")
    }

    /// A, B, C… for candidate 0, 1, 2. Indices past Z are not reachable —
    /// the arbiter only ever compares the two engines — but the label stays
    /// well-defined rather than crashing if that changes.
    static func label(for index: Int) -> String {
        guard index >= 0, index < 26,
              let scalar = Unicode.Scalar(UInt32(65 + index))
        else { return "?" }
        return String(Character(scalar))
    }

    /// The first A-Z letter in the reply, as a candidate index.
    ///
    /// Deliberately literal: with `max_tokens` this small and a one-letter
    /// output rule, the reply is "A" or "B". A model that answers "Option B"
    /// parses to O, lands out of range, and the caller abstains — the reply is
    /// logged so that failure mode is visible rather than silently mapped to
    /// the wrong engine.
    static func firstLabelIndex(in reply: String) -> Int? {
        for scalar in reply.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A: return Int(scalar.value) - 0x41   // A-Z
            case 0x61...0x7A: return Int(scalar.value) - 0x61   // a-z
            default: continue
            }
        }
        return nil
    }

    /// First text block of a non-streaming Messages response, trimmed.
    static func replyText(from data: Data) -> String? {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        guard let json = parsed as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { return nil }

        for block in content where block["type"] as? String == "text" {
            guard let text = (block["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { continue }
            return text
        }
        return nil
    }
}
