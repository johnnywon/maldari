import Foundation

/// Tier 2 of transcript arbitration, run as a three-round debate between
/// several model agents instead of a single-shot judge.
///
/// ## Why a debate and not one call
///
/// The failure this type exists to prevent, from a real session: the user spoke
/// English while the app was in `koreanOnly` mode, where the only engine is
/// RTZR running `sommers_ko`. RTZR *cannot* fail on English — it has no English
/// model — so it wrote the English phonemes down as Hangul that reads like
/// fluent Korean ("하다 마이님 쬐하네" for "how do I mind …") and reported 0.86
/// confidence. Nothing downstream doubted it. The translator was handed Korean
/// gibberish, had no rule for unintelligible input, and answered
/// conversationally — "I'm unable to parse that input with confidence. Could
/// you please repeat or clarify what you said?" — and *that plea was printed as
/// the translation*, written to the session recording, and uploaded to the
/// cloud.
///
/// A single judge shown both candidates side by side anchors on whichever text
/// reads more fluently, which is precisely the wrong instinct here: mis-heard
/// English reads perfectly fluently as Korean syllables. So round 1 asks each
/// advocate about ONE transcript with the rival withheld — an advocate that has
/// already seen the answer is no longer independent evidence. Round 2 makes
/// each side confront the rival and either defend or concede. Round 3 picks a
/// winner and may return a *corrected* transcript and language, which is how
/// the mis-heard-English case gets repaired rather than merely picked.
///
/// ## This class never throws
///
/// Every failure — missing key, HTTP error, garbled JSON, deadline,
/// cancellation — becomes `nil` plus a log line. Returning nil leaves the
/// caller's cheap deterministic pick standing, and that pick is already on
/// screen; a thrown error would take a good transcript down with a bad debate.
final class TranscriptDebate: TranscriptJudging {

    typealias Candidate = TranscriptArbiter.Candidate

    /// How the debate reaches the network. A closure rather than a `URLSession`
    /// so tests can drive all three rounds without a socket and assert the
    /// exact request bodies — see `init(transport:apiKey:budget:)`.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    // MARK: - Tunables

    /// Reuses the translator's model deliberately: the debate is five cheap
    /// side-calls on the same account, and pinning every tier to one model keeps
    /// per-meeting cost predictable.
    static let model = ClaudeTranslationService.model

    /// Measured, not guessed: at 4 seconds this abstained on every real case.
    /// Three sequential rounds of Haiku returning JSON — two of them fan-outs — cost
    /// 4-8s against the live API, so a 4s ceiling meant the debate never once
    /// delivered a verdict and the whole tier was dead weight. 12s is affordable
    /// precisely because this runs AFTER the cheap pick is already on screen and
    /// arrives as a correction; the cost of being slow is a late correction, while
    /// the cost of being too strict is no correction ever.
    ///
    /// HARD ceiling on the whole debate, wall clock, enforced as a *deadline*
    /// rather than as three per-call timeouts.
    ///
    /// Three 4-second timeouts would permit a 12-second debate. The deadline is
    /// computed once, up front, so a slow round 1 eats into round 3's budget
    /// instead of extending the total. The budget is larger than the single
    /// judge's 1.2s on purpose — this runs *after* the cheap pick is already on
    /// the guest's screen and lands as a correction — but it is not unbounded,
    /// because a correction that arrives after the room has moved on reads as a
    /// glitch rather than a fix.
    static let totalBudget: TimeInterval = 12.0

    /// A verdict below this does not get to overwrite what is already on screen.
    ///
    /// The user's requirement is that "the winning side convinced of its
    /// accuracy" is what gets printed. Since the cheap pick has already been
    /// shown to the room, replacing that line is only worth the visual churn if
    /// the debate actually settled something. 0.7 sits deliberately above the
    /// midpoint: a verdict at 0.5 means round 3 is coin-flipping between two
    /// positions, and a coin-flip rewrite of a line people have already read is
    /// worse than leaving the heuristic's answer alone. The number is logged on
    /// every abstention so it can be re-tuned against real meetings instead of
    /// intuition.
    static let minimumConfidence: Double = 0.7

    /// How many finalized lines of context to send. Enough to establish who is
    /// talking about what; short enough that five prompts stay small.
    static let contextLines = 3

    /// Context lines are trimmed — a runaway earlier line must not push this
    /// debate past the deadline above.
    private static let maxContextChars = 200

    /// Diagnostics only. Full transcripts live in the session recording; the log
    /// just needs enough to identify which line was debated.
    private static let logTextChars = 80

    /// Ceiling on a corrected transcript, relative to the winner's own text.
    ///
    /// A tripwire, not a rule. The incident behind this whole file is a model's
    /// conversational sentence being printed as content, so a "correction" that
    /// runs several times longer than the audio's own transcript is treated as
    /// prose leaking into the `text` field: the winner still wins, but its own
    /// words are used. Mis-heard English legitimately changes length (Hangul
    /// syllables vs. English words), so the ratio is generous, and short
    /// utterances get a flat floor instead — 4x of a three-syllable line is a
    /// dozen characters, which would reject perfectly good repairs. The absolute
    /// cap is the backstop for a long candidate paired with a rambling reply.
    private static let maxCorrectionRatio = 4.0
    private static let minCorrectionChars = 80
    private static let maxCorrectionChars = 400

    // MARK: - Rounds

    /// The three rounds, each with its own byte-stable system prompt.
    ///
    /// Byte-stability is the point of these being `static let` on an enum:
    /// Anthropic prompt caching keys on the exact system block, so interpolating
    /// anything here (a candidate, the language, a timestamp) would defeat the
    /// cache on every request. Everything that varies lives in the user turn.
    /// Note these prompts sit near Haiku's minimum cacheable prefix, so the
    /// `cache_control` marker may currently be a no-op; keeping the constants
    /// stable makes the saving free if the rules grow.
    enum Round: Int, CaseIterable {
        case advocacy = 1
        case crossExamination = 2
        case verdict = 3

        var systemPrompt: String {
            switch self {
            case .advocacy: return TranscriptDebate.advocacySystemPrompt
            case .crossExamination: return TranscriptDebate.crossExaminationSystemPrompt
            case .verdict: return TranscriptDebate.verdictSystemPrompt
            }
        }

        /// Replies are one small JSON object. The cap bounds the worst case if a
        /// round ignores the output rule and starts explaining itself — which
        /// would otherwise spend the whole deadline generating prose.
        var maxTokens: Int {
            switch self {
            case .advocacy, .crossExamination: return 400
            case .verdict: return 500
            }
        }
    }

    static let advocacySystemPrompt = """
        You are one advocate in a debate about what a person actually said in a \
        live business meeting that is being translated between Korean and \
        English in real time.

        You will be shown ONE candidate transcript, from ONE speech-recognition \
        engine, plus the last few finalized lines of the meeting. You will NOT \
        be shown what any other engine heard, and you must not speculate about \
        it. Withholding it is deliberate: an advocate who has already seen the \
        rival's answer stops being independent evidence.

        THE FAILURE THAT MATTERS MOST. One engine in this system runs a \
        Korean-only acoustic model. It cannot produce English, so when someone \
        speaks ENGLISH at it, it does not fail and does not fall silent — it \
        writes the English sounds down as Hangul syllables. The result reads \
        like fluent Korean and is often reported with HIGH confidence, but it is \
        not Korean at all: "how do I mind" came back as "하다 마이님". So Hangul \
        that is grammatically loose, semantically empty, or made of words that \
        do not belong together in a business meeting is your prime suspect. \
        Sound the syllables out and check whether English lands underneath them.

        ENGINE-REPORTED CONFIDENCE IS NOT EVIDENCE. Measured on real sessions, \
        this system's Korean engine reported 0.08 for a perfectly correct \
        "안녕하세요" and 0.86 for pure gibberish. Treat any number the engine \
        reports as noise and judge the words.

        JUDGE ON: whether this reads like a sentence a person would really speak \
        in this language, including the normal disfluency of live speech; \
        whether proper nouns, product names and figures hang together; whether \
        it continues the preceding lines of the meeting. Do NOT judge \
        punctuation, capitalization, formatting or politeness — the more \
        faithful transcript wins even when it is the messier one.

        OUTPUT. Reply with a single JSON object and nothing else. No prose \
        before or after it, no code fence, no comments.

        {"plausible": true, "language": "ko", "misheard_english": null, \
        "argument": "", "confidence": 0.0}

        plausible - true if this is a plausible verbatim record of real speech.
        language - "ko" or "en": the language you believe was actually SPOKEN, \
        which is not always the script it was written in.
        misheard_english - if this is Hangul that is really mis-heard English, \
        the English you believe was said; otherwise null.
        argument - one or two sentences, the strongest honest case for this \
        transcript.
        confidence - 0 to 1, calibrated. Use a low number when you are \
        guessing. Overconfidence here corrupts the whole debate.
        

        NEVER TRANSLATE. Your output is a TRANSCRIPT of what was spoken, in the         language it was spoken in. Translation is a separate system's job and         happens after you. If the candidates are Korean, the correct transcript is         Korean; returning English for Korean speech destroys the line — it replaces         the Korean the room actually heard, relabels the utterance as English, and         the translator then renders your English back into Korean.

        The one case where the language legitimately changes is a MIS-HEARING: a         Korean-only recognizer fed English speech emits Hangul that is a phonetic         rendering of English words, not Korean at all (e.g. "쿠쥬 센드 댓" for         "could you send that"). Only then may you report the English that was         actually said, and you must say so explicitly. Ordinary, meaningful Korean         is never this case.
        """

    static let crossExaminationSystemPrompt = """
        You are an advocate in a debate about what a person actually said in a \
        live business meeting. You have already argued for one transcript \
        without seeing any other. You are now shown the rival transcript and \
        the rival's argument.

        Your job is to reach the right answer, not to win. CONCEDING WHEN THE \
        RIVAL IS BETTER IS THE CORRECT AND EXPECTED OUTCOME. It is not a \
        failure and it is not a loss. An advocate who never concedes turns this \
        debate into theatre and gets a wrong transcript printed on a screen in \
        front of meeting guests. If the rival's reading is the more likely \
        record of the audio, concede and say why in one sentence.

        Keep in mind while you weigh them:

        One engine in this system runs a Korean-only acoustic model and cannot \
        produce English. Given English audio it emits Hangul that reads like \
        fluent Korean but is really English sounds spelled in Korean syllables \
        ("how do I mind" came back as "하다 마이님"). If one side is Hangul that \
        says nothing a person would say in a meeting, and the other side is \
        English that does, that is not a close call.

        Engine-reported confidence is noise, not evidence: this system's Korean \
        engine reported 0.08 for a correct "안녕하세요" and 0.86 for gibberish. \
        Neither side may lean on it.

        Punctuation, capitalization and politeness are irrelevant. The more \
        faithful transcript wins even when it is the messier one.

        OUTPUT. Reply with a single JSON object and nothing else. No prose \
        before or after it, no code fence, no comments.

        {"concede": false, "argument": "", "confidence": 0.0}

        concede - true if the rival's transcript is the better record of what \
        was said.
        argument - one or two sentences: your defence, or your reason for \
        conceding.
        confidence - 0 to 1, how sure you now are about YOUR OWN transcript. If \
        you are conceding, this must be low.
        

        NEVER TRANSLATE. Your output is a TRANSCRIPT of what was spoken, in the         language it was spoken in. Translation is a separate system's job and         happens after you. If the candidates are Korean, the correct transcript is         Korean; returning English for Korean speech destroys the line — it replaces         the Korean the room actually heard, relabels the utterance as English, and         the translator then renders your English back into Korean.

        The one case where the language legitimately changes is a MIS-HEARING: a         Korean-only recognizer fed English speech emits Hangul that is a phonetic         rendering of English words, not Korean at all (e.g. "쿠쥬 센드 댓" for         "could you send that"). Only then may you report the English that was         actually said, and you must say so explicitly. Ordinary, meaningful Korean         is never this case.
        """

    static let verdictSystemPrompt = """
        You are the judge at the end of a debate about what a person actually \
        said in one short stretch of live meeting audio. Each transcript came \
        from a different speech-recognition engine. Each was argued for blind, \
        then cross-examined against the others. You now see every position and \
        decide.

        Pick the transcript that is the more faithful record of what was \
        spoken. Weigh the arguments, not the engines' own confidence scores, \
        which are known to be worthless here (0.08 for a correct "안녕하세요", \
        0.86 for pure gibberish). A concession from one side is strong evidence \
        for the other.

        YOU MAY CORRECT THE WINNER. One engine in this system is Korean-only and \
        cannot produce English: given English audio it writes the English sounds \
        down as Hangul ("how do I mind" came back as "하다 마이님"). When that is \
        what happened, return the English in "text" and "en" in "language" — \
        that repair is the main reason those fields exist. Otherwise correct \
        only a clear local mis-hearing. Never invent content the audio does not \
        support, never translate, never add punctuation or tidy the wording, and \
        never write a sentence addressed to anyone. The value of "text" is a \
        transcript of speech, not a message.

        BE HONEST ABOUT DOUBT. This verdict arrives after a transcript is \
        already showing on a guest-facing screen, and it only replaces that line \
        when your confidence is high. A hedged verdict is wanted and is safe: it \
        leaves the existing line alone. An overconfident wrong verdict replaces \
        a correct line with a wrong one in front of the room.

        OUTPUT. Reply with a single JSON object and nothing else. No prose \
        before or after it, no code fence, no comments.

        {"winner": "", "text": null, "language": null, "confidence": 0.0, \
        "reasoning": ""}

        winner - the engine name, spelled exactly as it appears in the \
        positions below.
        text - the corrected transcript, or null to use the winner's own text \
        verbatim.
        language - "ko" or "en" if the winner's language is mislabelled, else \
        null.
        confidence - 0 to 1, calibrated: how sure you are that the text you are \
        returning is what was said.
        reasoning - ONE line.
        

        NEVER TRANSLATE. Your output is a TRANSCRIPT of what was spoken, in the         language it was spoken in. Translation is a separate system's job and         happens after you. If the candidates are Korean, the correct transcript is         Korean; returning English for Korean speech destroys the line — it replaces         the Korean the room actually heard, relabels the utterance as English, and         the translator then renders your English back into Korean.

        The one case where the language legitimately changes is a MIS-HEARING: a         Korean-only recognizer fed English speech emits Hangul that is a phonetic         rendering of English words, not Korean at all (e.g. "쿠쥬 센드 댓" for         "could you send that"). Only then may you report the English that was         actually said, and you must say so explicitly. Ordinary, meaningful Korean         is never this case.
        """

    // MARK: - Wire

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Both timeouts are set, and both are needed: the request timeout is a
    /// per-byte idle gap, so a connection that trickles bytes would never trip
    /// it. `timeoutIntervalForResource` is what bounds a single round in wall
    /// clock. The deadline in `judge` is what bounds the debate as a whole.
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TranscriptDebate.totalBudget
        config.timeoutIntervalForResource = TranscriptDebate.totalBudget
        return URLSession(configuration: config)
    }()

    private let transport: Transport
    private let apiKey: @Sendable () -> String?
    private let budget: TimeInterval

    /// Designated init, and the test seam.
    ///
    /// `apiKey` is a closure rather than a direct Keychain read so the
    /// no-key-means-no-request path is assertable on a machine that happens to
    /// have a real key installed. `budget` is injectable for the same reason:
    /// the deadline path should be testable without a four-second test.
    init(
        transport: @escaping Transport,
        apiKey: @escaping @Sendable () -> String? = { Credentials.get(.anthropicAPIKey) },
        budget: TimeInterval = TranscriptDebate.totalBudget
    ) {
        self.transport = transport
        self.apiKey = apiKey
        self.budget = budget
    }

    convenience init(session: URLSession = TranscriptDebate.defaultSession) {
        self.init(transport: { try await session.data(for: $0) })
    }

    /// True when every candidate is saying the same thing, so there is no dispute.
    ///
    /// Uses the arbiter's own token divergence rather than string equality, because
    /// two engines routinely differ only in punctuation or spacing and that is not a
    /// disagreement about what was said.
    static func candidatesAgree(_ candidates: [Candidate]) -> Bool {
        guard let first = candidates.first else { return true }
        return candidates.dropFirst().allSatisfy {
            TranscriptArbiter.divergence(first.text, $0.text) < agreementDivergence
        }
    }

    /// Below this token divergence, candidates count as agreeing. Deliberately
    /// tighter than `TranscriptArbiter.materialDivergence`: that constant decides
    /// whether a disagreement is worth escalating, this one decides whether there is
    /// a disagreement at all, and being wrong here means refusing to arbitrate a
    /// real conflict.
    static let agreementDivergence: Double = 0.05

    // MARK: - Debate

    func judge(
        candidates: [Candidate],
        language: Language,
        context: [String]
    ) async -> JudgeVerdict? {
        // Fewer than two candidates is not a disagreement, and a debate with
        // one side is the single-judge failure mode wearing a costume.
        guard candidates.count >= 2 else {
            DiagnosticLog.shared.info("stt", "debate_abstained", [
                "reason": "needs at least two candidates",
                "candidates": candidates.count,
            ])
            return nil
        }

        // Candidates that already agree are not in dispute, so there is nothing to
        // arbitrate and no reason to spend three model calls discovering it.
        //
        // This is a safety guard, not an optimisation. Asked to produce "the correct
        // transcript" for two IDENTICAL Korean candidates, the debate TRANSLATED it:
        // it returned "mold cost is billed separately" with `language: en` for
        // 금형 비용은 별도로 청구됩니다. Applied, that replaces a Korean source with
        // English, relabels the utterance English, and then has the translator render
        // it back into Korean — the line is destroyed. The prompts now forbid
        // translating explicitly, and this guard removes the easiest way to trip it.
        if Self.candidatesAgree(candidates) {
            DiagnosticLog.shared.info("stt", "debate_abstained", [
                "reason": "candidates agree; nothing to arbitrate",
                "text": String(candidates[0].text.prefix(Self.logTextChars)),
            ])
            return nil
        }

        // No key means no debate, and no network call to discover that.
        guard let apiKey = apiKey() else {
            DiagnosticLog.shared.warn("stt", "debate_abstained", [
                "reason": "anthropic api key not configured",
            ])
            return nil
        }

        let started = Date()
        let deadline = started.addingTimeInterval(budget)
        func elapsedMS() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        DiagnosticLog.shared.info("stt", "debate_started", [
            "language": language.rawValue,
            "candidates": candidates.count,
            "texts": Self.logTexts(candidates),
            "budget_ms": Int(budget * 1000),
        ])

        var positions = candidates.map { Position(candidate: $0) }
        let transport = self.transport

        do {
            // Round 1 — blind advocacy, one call per candidate, in parallel.
            let advocacies = try await Self.advocacyRound(
                positions: positions, language: language, context: context,
                apiKey: apiKey, transport: transport, deadline: deadline)
            for index in positions.indices {
                positions[index].advocacy = advocacies[index]
            }
            DiagnosticLog.shared.info("stt", "debate_round", [
                "round": Round.advocacy.rawValue,
                "confidence": Self.logConfidence(positions) { $0.advocacy?.confidence },
                "latency_ms": elapsedMS(),
            ])

            // Round 2 — cross-examination. Each advocate now sees the rivals'
            // transcripts and round-1 arguments, and may concede.
            let rebuttals = try await Self.crossExaminationRound(
                positions: positions, language: language, context: context,
                apiKey: apiKey, transport: transport, deadline: deadline)
            for index in positions.indices {
                positions[index].rebuttal = rebuttals[index]
            }
            DiagnosticLog.shared.info("stt", "debate_round", [
                "round": Round.crossExamination.rawValue,
                "confidence": Self.logConfidence(positions) { $0.rebuttal?.confidence },
                "latency_ms": elapsedMS(),
            ])
            for position in positions where position.rebuttal?.conceded == true {
                DiagnosticLog.shared.info("stt", "debate_conceded", [
                    "engine": position.candidate.engine.rawValue,
                    "confidence": position.rebuttal?.confidence ?? 0,
                    "text": String(position.candidate.text.prefix(Self.logTextChars)),
                ])
            }

            // Round 3 — verdict.
            let reply = try await Self.reply(
                to: Self.makeRequest(
                    round: .verdict, apiKey: apiKey,
                    userPrompt: Self.verdictPrompt(
                        positions: positions, language: language, context: context)),
                transport: transport, deadline: deadline)
            guard let decision = Self.verdict(from: reply, candidates: candidates) else {
                DiagnosticLog.shared.error("stt", "debate_failed", [
                    "error": "unusable verdict",
                    "reply": String(reply.prefix(200)),
                    "latency_ms": elapsedMS(),
                ])
                return nil
            }

            // "The winning side convinced of its accuracy is printed" — so a
            // hedging verdict must not overwrite what is already on screen.
            guard decision.confidence >= Self.minimumConfidence else {
                DiagnosticLog.shared.info("stt", "debate_abstained", [
                    "reason": "verdict below minimum confidence",
                    "winner": decision.engine.rawValue,
                    "confidence": decision.confidence,
                    "minimum": Self.minimumConfidence,
                    "latency_ms": elapsedMS(),
                ])
                return nil
            }

            DiagnosticLog.shared.info("stt", "debate_verdict", [
                "winner": decision.engine.rawValue,
                "confidence": decision.confidence,
                "corrected": decision.text != nil,
                "language": decision.language?.rawValue ?? "unchanged",
                "text": String((decision.text ?? "").prefix(Self.logTextChars)),
                "reasoning": String(decision.reasoning.prefix(200)),
                "latency_ms": elapsedMS(),
            ])
            return decision
        } catch DebateError.timedOut {
            DiagnosticLog.shared.warn("stt", "debate_abstained", [
                "reason": "deadline exceeded",
                "latency_ms": elapsedMS(),
                "limit_ms": Int(budget * 1000),
            ])
            return nil
        } catch let error as URLError where error.code == .timedOut {
            DiagnosticLog.shared.warn("stt", "debate_abstained", [
                "reason": "request timed out",
                "latency_ms": elapsedMS(),
            ])
            return nil
        } catch let error as URLError where error.code == .cancelled {
            // The utterance moved on (a later revision superseded it, or the
            // session stopped). Expected, not a fault.
            DiagnosticLog.shared.info("stt", "debate_abstained", [
                "reason": "cancelled",
                "latency_ms": elapsedMS(),
            ])
            return nil
        } catch is CancellationError {
            DiagnosticLog.shared.info("stt", "debate_abstained", [
                "reason": "cancelled",
                "latency_ms": elapsedMS(),
            ])
            return nil
        } catch {
            DiagnosticLog.shared.error("stt", "debate_failed", [
                "error": Self.describe(error),
                "latency_ms": elapsedMS(),
            ])
            return nil
        }
    }

    // MARK: - Positions

    /// One side of the debate: an engine's transcript plus whatever it has
    /// argued so far. Rounds fill this in as they complete, so round 3 can see
    /// the whole history in one place.
    struct Position: Equatable, Sendable {
        let candidate: Candidate
        var advocacy: Advocacy?
        var rebuttal: Rebuttal?
    }

    /// An advocate's round-1 position, formed without seeing any rival.
    struct Advocacy: Equatable, Sendable {
        let engine: STTEngine
        let plausible: Bool
        /// The language the advocate believes was *spoken*, which is not always
        /// the script the transcript is written in.
        let language: Language?
        /// The English this text would be, if it is a Korean-only recognizer
        /// mis-hearing English. nil when the advocate does not think it is.
        let mishearedEnglish: String?
        let argument: String
        /// The advocate's own calibrated confidence, 0...1.
        let confidence: Double
    }

    /// An advocate's round-2 position, formed after seeing the rivals.
    struct Rebuttal: Equatable, Sendable {
        let engine: STTEngine
        /// True when this advocate agrees a rival's transcript is better.
        /// Conceding is the expected outcome half the time, not an error.
        let conceded: Bool
        let argument: String
        let confidence: Double
    }

    // MARK: - Rounds 1 and 2 (parallel)

    /// Round 1. One call per candidate, concurrently, each seeing only its own
    /// transcript. Results come back in candidate order.
    ///
    /// Any advocate that fails or replies unparseably aborts the debate: with a
    /// missing position, round 3 would be judging a one-sided argument, which
    /// is the failure mode this whole design replaced.
    private static func advocacyRound(
        positions: [Position],
        language: Language,
        context: [String],
        apiKey: String,
        transport: @escaping Transport,
        deadline: Date
    ) async throws -> [Advocacy] {
        try await withThrowingTaskGroup(of: (Int, Advocacy).self) { group in
            for (index, position) in positions.enumerated() {
                let engine = position.candidate.engine
                let request = try makeRequest(
                    round: .advocacy, apiKey: apiKey,
                    userPrompt: advocacyPrompt(
                        for: position.candidate, language: language, context: context))
                group.addTask {
                    let text = try await reply(
                        to: request, transport: transport, deadline: deadline)
                    guard let claim = advocacy(from: text, engine: engine) else {
                        throw DebateError.unparseable("round 1 \(engine.rawValue): \(text)")
                    }
                    return (index, claim)
                }
            }
            var claims: [Int: Advocacy] = [:]
            for try await (index, claim) in group { claims[index] = claim }
            return try positions.indices.map { index in
                guard let claim = claims[index] else {
                    throw DebateError.unparseable("round 1 missing advocate \(index)")
                }
                return claim
            }
        }
    }

    /// Round 2. One call per candidate, concurrently, each now seeing the
    /// rivals' transcripts and round-1 arguments.
    private static func crossExaminationRound(
        positions: [Position],
        language: Language,
        context: [String],
        apiKey: String,
        transport: @escaping Transport,
        deadline: Date
    ) async throws -> [Rebuttal] {
        try await withThrowingTaskGroup(of: (Int, Rebuttal).self) { group in
            for (index, position) in positions.enumerated() {
                let engine = position.candidate.engine
                let rivals = positions.filter { $0.candidate.engine != engine }
                let request = try makeRequest(
                    round: .crossExamination, apiKey: apiKey,
                    userPrompt: crossExaminationPrompt(
                        for: position, rivals: rivals,
                        language: language, context: context))
                group.addTask {
                    let text = try await reply(
                        to: request, transport: transport, deadline: deadline)
                    guard let claim = rebuttal(from: text, engine: engine) else {
                        throw DebateError.unparseable("round 2 \(engine.rawValue): \(text)")
                    }
                    return (index, claim)
                }
            }
            var claims: [Int: Rebuttal] = [:]
            for try await (index, claim) in group { claims[index] = claim }
            return try positions.indices.map { index in
                guard let claim = claims[index] else {
                    throw DebateError.unparseable("round 2 missing advocate \(index)")
                }
                return claim
            }
        }
    }

    // MARK: - Transport

    private enum DebateError: Error {
        case timedOut
        case http(Int, String)
        case unparseable(String)
    }

    /// One request, to first text block, bounded by the shared deadline.
    ///
    /// The whole request/parse runs inside the raced closure so nothing but a
    /// `String` crosses the task-group boundary — a `URLResponse` would drag a
    /// reference type through a `Sendable` position for no reason.
    private static func reply(
        to request: URLRequest,
        transport: @escaping Transport,
        deadline: Date
    ) async throws -> String {
        try await before(deadline) {
            let (data, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                throw DebateError.http(
                    status, String(data: data, encoding: .utf8) ?? "")
            }
            guard let text = replyText(from: data) else {
                throw DebateError.unparseable("no text block in response")
            }
            return text
        }
    }

    /// Runs `work`, giving up the moment `deadline` passes.
    ///
    /// A deadline, not a timeout: `deadline` is computed once for the whole
    /// debate, so every round races the same wall-clock instant and a slow
    /// round 1 cannot let round 3 run late.
    private static func before<T: Sendable>(
        _ deadline: Date,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw DebateError.timedOut }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                throw DebateError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DebateError.timedOut }
            return first
        }
    }

    /// Static and pure so tests can assert the exact body and the exact prompt
    /// without a network stub — same shape as `ClaudeTranscriptJudge.makeRequest`.
    static func makeRequest(
        round: Round,
        apiKey: String,
        userPrompt: String
    ) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": round.maxTokens,
            "system": [
                ["type": "text",
                 "text": round.systemPrompt,
                 "cache_control": ["type": "ephemeral"]]
            ],
            "messages": [
                ["role": "user", "content": userPrompt]
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

    /// Text blocks of a non-streaming Messages response, concatenated.
    ///
    /// Concatenated rather than first-only: a model that emits its JSON split
    /// across two text blocks would otherwise hand us half an object, and a
    /// truncated object parses to nothing at all.
    static func replyText(from data: Data) -> String? {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        guard let json = parsed as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { return nil }

        var text = ""
        for block in content where block["type"] as? String == "text" {
            text += (block["text"] as? String) ?? ""
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - User prompts
    //
    // Everything that varies per call lives here rather than in the system
    // block, so the system block stays byte-identical — see `Round`.

    static func advocacyPrompt(
        for candidate: Candidate,
        language: Language,
        context: [String]
    ) -> String {
        var lines = contextBlock(context)
        lines.append("The cheap heuristic guessed this line is \(language.displayName), "
            + "but it cannot tell mis-heard English from Korean, so treat that as a hint.")
        lines.append("")
        lines.append(contentsOf: describe(candidate))
        lines.append("")
        lines.append("Argue for this transcript. Reply with the JSON object only.")
        return lines.joined(separator: "\n")
    }

    static func crossExaminationPrompt(
        for position: Position,
        rivals: [Position],
        language: Language,
        context: [String]
    ) -> String {
        var lines = contextBlock(context)
        lines.append("YOUR POSITION")
        lines.append(contentsOf: describe(position.candidate))
        if let advocacy = position.advocacy {
            lines.append("Your argument: \(advocacy.argument)")
            lines.append("Your confidence: \(format(advocacy.confidence))")
            if let english = advocacy.mishearedEnglish {
                lines.append("You said this may really be English: \(english)")
            }
        }
        lines.append("")
        for rival in rivals {
            lines.append("RIVAL POSITION")
            lines.append(contentsOf: describe(rival.candidate))
            if let advocacy = rival.advocacy {
                lines.append("Their argument: \(advocacy.argument)")
                lines.append("Their confidence: \(format(advocacy.confidence))")
                lines.append("Language they believe was spoken: "
                    + (advocacy.language?.displayName ?? "unstated"))
                if let english = advocacy.mishearedEnglish {
                    lines.append("They said their text may really be English: \(english)")
                }
            }
            lines.append("")
        }
        lines.append("Defend your transcript or concede to the rival. "
            + "Reply with the JSON object only.")
        return lines.joined(separator: "\n")
    }

    static func verdictPrompt(
        positions: [Position],
        language: Language,
        context: [String]
    ) -> String {
        var lines = contextBlock(context)
        lines.append("The cheap heuristic guessed this line is \(language.displayName). "
            + "It cannot tell mis-heard English from Korean, so it may be wrong.")
        lines.append("")
        for position in positions {
            lines.append("POSITION: \(position.candidate.engine.rawValue)")
            lines.append(contentsOf: describe(position.candidate))
            if let advocacy = position.advocacy {
                lines.append("Round 1 argument: \(advocacy.argument)")
                lines.append("Round 1 plausible: \(advocacy.plausible)")
                lines.append("Round 1 language spoken: "
                    + (advocacy.language?.displayName ?? "unstated"))
                if let english = advocacy.mishearedEnglish {
                    lines.append("Round 1 mis-heard English reading: \(english)")
                }
                lines.append("Round 1 confidence: \(format(advocacy.confidence))")
            }
            if let rebuttal = position.rebuttal {
                lines.append("Round 2 conceded: \(rebuttal.conceded)")
                lines.append("Round 2 argument: \(rebuttal.argument)")
                lines.append("Round 2 confidence: \(format(rebuttal.confidence))")
            }
            lines.append("")
        }
        lines.append("Decide. Reply with the JSON object only.")
        return lines.joined(separator: "\n")
    }

    private static func contextBlock(_ context: [String]) -> [String] {
        let recent = context.suffix(contextLines).filter { !$0.isEmpty }
        guard !recent.isEmpty else { return [] }
        var lines = ["Preceding lines of this meeting:"]
        for line in recent {
            lines.append("- " + String(line.prefix(maxContextChars)))
        }
        lines.append("")
        return lines
    }

    private static func describe(_ candidate: Candidate) -> [String] {
        [
            "Engine: \(candidate.engine.rawValue) (\(capability(of: candidate.engine)))",
            "Engine-reported language: "
                + (candidate.reportedLanguage?.displayName ?? "not reported"),
            "Engine-reported confidence: \(format(candidate.confidence)) (unreliable)",
            "Transcript: \(candidate.text)",
        ]
    }

    /// Described through `nativeLanguage` rather than by engine name, so a new
    /// engine gets an accurate description the day it is added.
    private static func capability(of engine: STTEngine) -> String {
        switch engine.nativeLanguage {
        case .ko:
            return "Korean-only model; it cannot output English, "
                + "so English audio comes back as Hangul"
        case .en:
            return "English-only model; it cannot output Korean, "
                + "so Korean audio comes back as English words"
        case nil:
            return "multilingual model; it can output either language"
        }
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "not reported" }
        return String(format: "%.2f", value)
    }

    // MARK: - Parsing
    //
    // Internal and pure so every malformed-output case is a unit test rather
    // than a live-fire surprise.

    /// Round-1 reply to an `Advocacy`, or nil if it is unusable.
    static func advocacy(from reply: String, engine: STTEngine) -> Advocacy? {
        guard let wire: AdvocacyWire = decode(reply),
              let confidence = clamped(wire.confidence)
        else { return nil }
        return Advocacy(
            engine: engine,
            plausible: wire.plausible ?? false,
            language: language(from: wire.language),
            mishearedEnglish: nonEmpty(wire.mishearedEnglish),
            argument: nonEmpty(wire.argument) ?? "",
            confidence: confidence)
    }

    /// Round-2 reply to a `Rebuttal`, or nil if it is unusable.
    static func rebuttal(from reply: String, engine: STTEngine) -> Rebuttal? {
        guard let wire: RebuttalWire = decode(reply),
              let confidence = clamped(wire.confidence)
        else { return nil }
        return Rebuttal(
            engine: engine,
            conceded: wire.concede ?? false,
            argument: nonEmpty(wire.argument) ?? "",
            confidence: confidence)
    }

    /// Round-3 reply to a `JudgeVerdict`, or nil if it is unusable.
    ///
    /// Rejects, rather than guesses, on: unparseable output; a winner that is
    /// not one of the candidates (the model naming an engine nobody entered
    /// means it lost track of the debate, and mapping it to a candidate anyway
    /// would publish the wrong engine's words); and a missing confidence, which
    /// is an abstention and never 1.0.
    ///
    /// Note the `minimumConfidence` gate is deliberately NOT here: this returns
    /// what the model said so the caller can log the number it rejected.
    static func verdict(from reply: String, candidates: [Candidate]) -> JudgeVerdict? {
        guard let wire: VerdictWire = decode(reply),
              let confidence = clamped(wire.confidence),
              let raw = nonEmpty(wire.winner)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let engine = STTEngine(rawValue: raw),
              let winner = candidates.first(where: { $0.engine == engine })
        else { return nil }

        return JudgeVerdict(
            engine: engine,
            text: correction(wire.text, for: winner),
            language: language(from: wire.language),
            confidence: confidence,
            reasoning: nonEmpty(wire.reasoning) ?? "")
    }

    /// A corrected transcript, or nil to use the winner's own text.
    ///
    /// Drops a correction that merely repeats the candidate (nothing to apply)
    /// and one that is wildly longer than it (see `maxCorrectionRatio`) — the
    /// original incident was a model's conversational sentence being printed as
    /// content, and this is the cheap tripwire for that shape.
    private static func correction(_ text: String?, for winner: Candidate) -> String? {
        guard let corrected = nonEmpty(text) else { return nil }
        guard corrected != winner.text else { return nil }
        let ceiling = max(
            Double(winner.text.count) * maxCorrectionRatio, Double(minCorrectionChars))
        guard Double(corrected.count) <= ceiling, corrected.count <= maxCorrectionChars
        else {
            DiagnosticLog.shared.warn("stt", "debate_failed", [
                "error": "corrected text rejected as implausibly long",
                "engine": winner.engine.rawValue,
                "candidate_chars": winner.text.count,
                "corrected_chars": corrected.count,
                "corrected": String(corrected.prefix(logTextChars)),
            ])
            return nil
        }
        return corrected
    }

    /// The first balanced `{…}` run in a reply, decoded.
    ///
    /// Deliberately tolerant, because models wrap JSON in ```json fences,
    /// prefix it with "Here is my answer:", and append a sentence after it.
    /// Scanning for one balanced brace run handles all three without a rule per
    /// wrapper. `JSONDecoder` rather than a dictionary walk so a boolean in a
    /// numeric field is a decode failure instead of silently becoming 1.0.
    private static func decode<T: Decodable>(_ reply: String) -> T? {
        guard let slice = jsonSlice(in: reply) else { return nil }
        return try? JSONDecoder().decode(T.self, from: slice)
    }

    /// The first balanced `{…}` run in `reply`, as UTF-8 data. Internal so the
    /// brace scanner is directly testable.
    static func jsonSlice(in reply: String) -> Data? {
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?

        for index in reply.indices {
            let character = reply[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { continue }   // stray brace in the prose
                depth -= 1
                if depth == 0, let start {
                    return String(reply[start...index]).data(using: .utf8)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// Confidence, clamped to 0...1. A MISSING confidence returns nil, which
    /// the callers treat as an abstention — never as certainty. A model that
    /// omits the field has not made a claim, and defaulting it to 1.0 would
    /// promote silence into the strongest possible vote.
    static func clamped(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    /// "ko"/"en", tolerating case, whitespace and the spelled-out names.
    static func language(from raw: String?) -> Language? {
        guard let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else { return nil }
        if let exact = Language(rawValue: value) { return exact }
        if value.hasPrefix("ko") { return .ko }
        if value.hasPrefix("en") { return .en }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: - Wire shapes
    //
    // Every field optional and decoded independently: one bad field must not
    // discard an otherwise usable reply.

    private struct AdvocacyWire: Decodable {
        var plausible: Bool?
        var language: String?
        var mishearedEnglish: String?
        var argument: String?
        var confidence: Double?

        enum CodingKeys: String, CodingKey {
            case plausible
            case language
            case mishearedEnglish = "misheard_english"
            case argument
            case confidence
        }

        init(from decoder: Decoder) throws {
            let json = try decoder.container(keyedBy: CodingKeys.self)
            plausible = json.lenient(Bool.self, .plausible)
            language = json.lenient(String.self, .language)
            mishearedEnglish = json.lenient(String.self, .mishearedEnglish)
            argument = json.lenient(String.self, .argument)
            confidence = json.lenient(Double.self, .confidence)
        }
    }

    private struct RebuttalWire: Decodable {
        var concede: Bool?
        var argument: String?
        var confidence: Double?

        enum CodingKeys: String, CodingKey {
            case concede, argument, confidence
        }

        init(from decoder: Decoder) throws {
            let json = try decoder.container(keyedBy: CodingKeys.self)
            concede = json.lenient(Bool.self, .concede)
            argument = json.lenient(String.self, .argument)
            confidence = json.lenient(Double.self, .confidence)
        }
    }

    private struct VerdictWire: Decodable {
        var winner: String?
        var text: String?
        var language: String?
        var confidence: Double?
        var reasoning: String?

        enum CodingKeys: String, CodingKey {
            case winner, text, language, confidence, reasoning
        }

        init(from decoder: Decoder) throws {
            let json = try decoder.container(keyedBy: CodingKeys.self)
            winner = json.lenient(String.self, .winner)
            text = json.lenient(String.self, .text)
            language = json.lenient(String.self, .language)
            confidence = json.lenient(Double.self, .confidence)
            reasoning = json.lenient(String.self, .reasoning)
        }
    }

    // MARK: - Diagnostics helpers

    private static func logTexts(_ candidates: [Candidate]) -> [String: Any] {
        var texts: [String: Any] = [:]
        for candidate in candidates {
            texts[candidate.engine.rawValue] = String(candidate.text.prefix(logTextChars))
        }
        return texts
    }

    private static func logConfidence(
        _ positions: [Position],
        _ value: (Position) -> Double?
    ) -> [String: Any] {
        var confidences: [String: Any] = [:]
        for position in positions {
            confidences[position.candidate.engine.rawValue] = value(position) ?? -1
        }
        return confidences
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DebateError.timedOut:
            return "deadline exceeded"
        case let DebateError.http(status, body):
            return "http \(status): \(body.prefix(300))"
        case let DebateError.unparseable(detail):
            return "unparseable: \(detail.prefix(300))"
        default:
            return error.localizedDescription
        }
    }
}

private extension KeyedDecodingContainer {
    /// `decodeIfPresent` that swallows a type mismatch instead of throwing.
    ///
    /// A strict decoder discards the whole object when one field has the wrong
    /// type, so a model that writes `"plausible": "yes"` would cost us the
    /// entire round — and the debate with it. One junk field should cost one
    /// field. The load-bearing exception is confidence: it stays strictly typed
    /// so `"confidence": true` decodes to nil (an abstention) rather than
    /// sneaking through as 1.0.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
