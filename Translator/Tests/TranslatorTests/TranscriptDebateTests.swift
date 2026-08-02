import XCTest
@testable import Translator

/// Everything here runs without a socket. The debate reaches the network
/// through an injected `Transport`, so the three-round flow, the abstention
/// rules and every malformed-reply shape are ordinary unit tests rather than
/// live-fire surprises.
///
/// Fixtures are the real incident: the user spoke English at a Korean-only
/// recognizer, which returned Hangul that reads like fluent Korean at 0.86
/// confidence. That is the case the debate exists to repair.
final class TranscriptDebateTests: XCTestCase {

    // MARK: - Fixtures

    private func candidate(
        _ engine: STTEngine,
        _ text: String,
        confidence: Double? = nil,
        reported: Language? = nil
    ) -> TranscriptArbiter.Candidate {
        TranscriptArbiter.Candidate(
            engine: engine, text: text,
            confidence: confidence, reportedLanguage: reported)
    }

    private var specialist: TranscriptArbiter.Candidate {
        candidate(.rtzr, hangulGibberish, confidence: 0.86)
    }

    private var generalist: TranscriptArbiter.Candidate {
        candidate(.openai, englishHeard, confidence: 0.42, reported: .en)
    }

    private var bothEngines: [TranscriptArbiter.Candidate] { [specialist, generalist] }

    private let context = ["다음 회의는 금요일 오후로 미루겠습니다"]

    // MARK: - jsonSlice: the shapes real models actually emit

    func test_cleanJSONObject_parses() {
        let reply = #"{"winner": "rtzr", "confidence": 0.9, "reasoning": "fluent"}"#
        let verdict = TranscriptDebate.verdict(from: reply, candidates: bothEngines)
        XCTAssertEqual(verdict?.engine, .rtzr)
        XCTAssertEqual(verdict?.confidence ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertEqual(verdict?.reasoning, "fluent")
    }

    func test_fencedCodeBlock_parses() {
        let reply = """
            ```json
            {"winner": "openai", "confidence": 0.88, "reasoning": "romanization"}
            ```
            """
        XCTAssertEqual(
            TranscriptDebate.verdict(from: reply, candidates: bothEngines)?.engine, .openai)
    }

    func test_prosePreambleAndTrailingSentence_parses() {
        let reply = """
            Here is my verdict, based on the concession in round 2:
            {"winner": "openai", "confidence": 0.75, "reasoning": "conceded"}
            Let me know if you need more detail.
            """
        XCTAssertEqual(
            TranscriptDebate.verdict(from: reply, candidates: bothEngines)?.engine, .openai)
    }

    /// A brace inside a string value must not close the object early — the
    /// scanner tracks string state and escapes, so this is the regression test
    /// for a naive "first { to last }" implementation.
    func test_bracesInsideStringValues_doNotTruncateTheObject() {
        let reply = #"{"winner": "rtzr", "reasoning": "said \"{maybe}\" mid-sentence", "confidence": 0.8}"#
        let verdict = TranscriptDebate.verdict(from: reply, candidates: bothEngines)
        XCTAssertEqual(verdict?.engine, .rtzr)
        XCTAssertEqual(verdict?.reasoning, #"said "{maybe}" mid-sentence"#)
    }

    func test_missingOptionalFields_stillYieldAVerdict() {
        // No text, no language, no reasoning: the winner's own text stands.
        let reply = #"{"winner": "rtzr", "confidence": 0.8}"#
        let verdict = TranscriptDebate.verdict(from: reply, candidates: bothEngines)
        XCTAssertEqual(verdict?.engine, .rtzr)
        XCTAssertNil(verdict?.text)
        XCTAssertNil(verdict?.language)
        XCTAssertEqual(verdict?.reasoning, "")
    }

    func test_malformedOutput_abstains() {
        XCTAssertNil(TranscriptDebate.verdict(from: "", candidates: bothEngines))
        XCTAssertNil(TranscriptDebate.verdict(from: "I think rtzr is right.",
                                              candidates: bothEngines))
        XCTAssertNil(TranscriptDebate.verdict(from: #"{"winner": "rtzr", "confid"#,
                                              candidates: bothEngines))
        XCTAssertNil(TranscriptDebate.verdict(from: #"["rtzr", 0.9]"#,
                                              candidates: bothEngines))
    }

    func test_confidenceOutOfRange_isClamped() {
        let high = TranscriptDebate.verdict(
            from: #"{"winner": "rtzr", "confidence": 1.4}"#, candidates: bothEngines)
        XCTAssertEqual(high?.confidence ?? -1, 1.0, accuracy: 0.0001)

        let low = TranscriptDebate.verdict(
            from: #"{"winner": "rtzr", "confidence": -0.5}"#, candidates: bothEngines)
        XCTAssertEqual(low?.confidence ?? -1, 0.0, accuracy: 0.0001)
    }

    /// A missing confidence is silence, not certainty. Treating it as 1.0 would
    /// promote a model that skipped the field into the strongest possible vote.
    func test_absentConfidence_abstains() {
        XCTAssertNil(TranscriptDebate.verdict(
            from: #"{"winner": "rtzr", "reasoning": "fluent"}"#, candidates: bothEngines))
    }

    /// `true` decodes as 1.0 through a dictionary walk. It must not.
    func test_booleanConfidence_abstains() {
        XCTAssertNil(TranscriptDebate.verdict(
            from: #"{"winner": "rtzr", "confidence": true}"#, candidates: bothEngines))
    }

    func test_nonFiniteConfidence_abstains() {
        // NaN and infinity are not representable in JSON, so they arrive as the
        // strings a model writes for them — which are not numbers either.
        XCTAssertNil(TranscriptDebate.verdict(
            from: #"{"winner": "rtzr", "confidence": "0.9"}"#, candidates: bothEngines))
    }

    func test_jsonSlice_returnsNilWhenThereIsNoObject() {
        XCTAssertNil(TranscriptDebate.jsonSlice(in: "no braces at all"))
        XCTAssertNil(TranscriptDebate.jsonSlice(in: "closing } before opening {"))
    }

    // MARK: - Winner validation

    /// A verdict naming an engine nobody entered means round 3 lost track of the
    /// debate. Mapping it onto a candidate anyway would publish the wrong
    /// engine's words.
    func test_winnerNotAmongCandidates_isRejected() {
        let onlySpecialist = [specialist, candidate(.rtzr, "another rtzr frame")]
        XCTAssertNil(TranscriptDebate.verdict(
            from: #"{"winner": "openai", "confidence": 0.95}"#,
            candidates: onlySpecialist))
    }

    func test_unknownEngineName_isRejected() {
        XCTAssertNil(TranscriptDebate.verdict(
            from: #"{"winner": "whisper", "confidence": 0.95}"#,
            candidates: bothEngines))
        XCTAssertNil(TranscriptDebate.verdict(
            from: #"{"winner": "", "confidence": 0.95}"#, candidates: bothEngines))
    }

    func test_engineNameIsMatchedTolerantly() {
        XCTAssertEqual(
            TranscriptDebate.verdict(
                from: #"{"winner": " OpenAI ", "confidence": 0.95}"#,
                candidates: bothEngines)?.engine,
            .openai)
    }

    // MARK: - Corrections

    func test_correctedTextAndLanguageAreCarried() {
        let reply = """
            {"winner": "openai", "text": "how do I mind the schedule", \
            "language": "English", "confidence": 0.9, "reasoning": "one word off"}
            """
        let verdict = TranscriptDebate.verdict(from: reply, candidates: bothEngines)
        XCTAssertEqual(verdict?.text, "how do I mind the schedule")
        XCTAssertEqual(verdict?.language, .en)
    }

    /// A "correction" that merely repeats the candidate is nothing to apply, and
    /// nil tells the caller to use the candidate's own text.
    func test_correctionIdenticalToTheCandidate_isDropped() {
        let reply = """
            {"winner": "openai", "text": "\(englishHeard)", "confidence": 0.9}
            """
        XCTAssertNil(TranscriptDebate.verdict(from: reply, candidates: bothEngines)?.text)
    }

    /// The tripwire for the original incident: a conversational sentence landing
    /// in a field that gets printed as a transcript. The pick survives; the
    /// prose does not.
    func test_implausiblyLongCorrection_isDroppedButThePickSurvives() {
        let plea = "I'm unable to parse that input with confidence. Could you please "
            + "repeat or clarify what you said? I want to make sure I give you an "
            + "accurate translation of the meeting audio rather than guessing at it."
        let reply = """
            {"winner": "rtzr", "text": "\(plea)", "confidence": 0.9}
            """
        let verdict = TranscriptDebate.verdict(from: reply, candidates: bothEngines)
        XCTAssertEqual(verdict?.engine, .rtzr)
        XCTAssertNil(verdict?.text)
    }

    // MARK: - Round 1 and round 2 parsing

    func test_advocacyParsesTheMisheardEnglishCase() {
        let reply = """
            {"plausible": false, "language": "ko", \
            "misheard_english": "how do I mind", "argument": "empty syllables", \
            "confidence": 0.15}
            """
        let claim = TranscriptDebate.advocacy(from: reply, engine: .rtzr)
        XCTAssertEqual(claim?.engine, .rtzr)
        XCTAssertEqual(claim?.plausible, false)
        XCTAssertEqual(claim?.language, .ko)
        XCTAssertEqual(claim?.mishearedEnglish, "how do I mind")
        XCTAssertEqual(claim?.confidence ?? -1, 0.15, accuracy: 0.0001)
    }

    func test_advocacyWithoutConfidence_abstains() {
        XCTAssertNil(TranscriptDebate.advocacy(
            from: #"{"plausible": true, "argument": "reads fine"}"#, engine: .rtzr))
    }

    func test_advocacyTreatsNullMisheardEnglishAsAbsent() {
        let claim = TranscriptDebate.advocacy(
            from: #"{"misheard_english": null, "confidence": 0.5}"#, engine: .openai)
        XCTAssertNil(claim?.mishearedEnglish)
        XCTAssertFalse(claim?.plausible ?? true)   // absent flag is not a yes
    }

    func test_rebuttalParsesAConcession() {
        let reply = """
            {"concede": true, "argument": "their English explains my syllables", \
            "confidence": 0.1}
            """
        let claim = TranscriptDebate.rebuttal(from: reply, engine: .rtzr)
        XCTAssertEqual(claim?.conceded, true)
        XCTAssertEqual(claim?.confidence ?? -1, 0.1, accuracy: 0.0001)
    }

    func test_rebuttalWithoutConfidence_abstains() {
        XCTAssertNil(TranscriptDebate.rebuttal(
            from: #"{"concede": true, "argument": "fine"}"#, engine: .rtzr))
    }

    // MARK: - Prompts

    /// Round 1's whole value is independence. An advocate that can see the rival
    /// transcript is no longer separate evidence, so the rival must not appear
    /// anywhere in the prompt.
    func test_advocacyPromptWithholdsTheRivalTranscript() {
        let prompt = TranscriptDebate.advocacyPrompt(
            for: specialist, language: .ko, context: context)
        XCTAssertTrue(prompt.contains(hangulGibberish))
        XCTAssertFalse(prompt.contains(englishHeard))
        XCTAssertFalse(prompt.contains("openai"))
    }

    func test_crossExaminationPromptShowsTheRivalAndItsArgument() {
        let mine = TranscriptDebate.Position(
            candidate: specialist,
            advocacy: TranscriptDebate.Advocacy(
                engine: .rtzr, plausible: true, language: .ko, mishearedEnglish: nil,
                argument: "reads as Korean", confidence: 0.6),
            rebuttal: nil)
        let rival = TranscriptDebate.Position(
            candidate: generalist,
            advocacy: TranscriptDebate.Advocacy(
                engine: .openai, plausible: true, language: .en,
                mishearedEnglish: nil, argument: "plain English", confidence: 0.8),
            rebuttal: nil)

        let prompt = TranscriptDebate.crossExaminationPrompt(
            for: mine, rivals: [rival], language: .ko, context: context)
        XCTAssertTrue(prompt.contains(hangulGibberish))
        XCTAssertTrue(prompt.contains(englishHeard))
        XCTAssertTrue(prompt.contains("plain English"))
    }

    /// The instruction that keeps the debate from being theatre.
    func test_crossExaminationPromptTellsAdvocatesConcedingIsCorrect() {
        XCTAssertTrue(TranscriptDebate.crossExaminationSystemPrompt
            .contains("CONCEDING WHEN THE RIVAL IS BETTER IS THE CORRECT AND EXPECTED OUTCOME"))
    }

    func test_everyRoundHasItsOwnSystemPrompt() {
        let prompts = TranscriptDebate.Round.allCases.map(\.systemPrompt)
        XCTAssertEqual(Set(prompts).count, TranscriptDebate.Round.allCases.count)
        for prompt in prompts { XCTAssertFalse(prompt.isEmpty) }
    }

    // MARK: - Wire format

    func test_requestCarriesTheCacheableSystemBlockAndTheModel() throws {
        let request = try TranscriptDebate.makeRequest(
            round: .verdict, apiKey: "sk-test", userPrompt: "decide")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = requestBody(request)
        XCTAssertEqual(body["model"] as? String, ClaudeTranslationService.model)
        XCTAssertEqual(body["max_tokens"] as? Int, TranscriptDebate.Round.verdict.maxTokens)

        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system[0]["text"] as? String, TranscriptDebate.verdictSystemPrompt)
        XCTAssertEqual(
            (system[0]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        XCTAssertEqual(userText(request), "decide")
    }

    // MARK: - Abstentions that cost nothing

    /// No key means no debate, and no network call to discover that. The key is
    /// injected rather than read from the Keychain so this holds on a machine
    /// that has a real key installed.
    func test_missingAPIKey_abstainsWithoutAnyRequest() async {
        let (debate, exchange) = makeDebate(apiKey: nil) { _ in (200, "{}") }
        let verdict = await debate.judge(
            candidates: bothEngines, language: .ko, context: context)
        XCTAssertNil(verdict)
        let count = await exchange.count
        XCTAssertEqual(count, 0)
    }

    func test_fewerThanTwoCandidates_abstainsWithoutAnyRequest() async {
        let (debate, exchange) = makeDebate { _ in (200, "{}") }
        let verdict = await debate.judge(
            candidates: [specialist], language: .ko, context: context)
        XCTAssertNil(verdict)
        let count = await exchange.count
        XCTAssertEqual(count, 0)
    }

    // MARK: - The full three-round debate

    func test_threeRoundDebate_returnsTheWinningSidesCorrectedTranscript() async throws {
        let (debate, exchange) = makeDebate(handler: happyPath)
        let verdict = await debate.judge(
            candidates: bothEngines, language: .ko, context: context)

        let decision = try XCTUnwrap(verdict)
        XCTAssertEqual(decision.engine, .openai)
        XCTAssertEqual(decision.text, "how do I mind the schedule")
        XCTAssertEqual(decision.language, .en)
        XCTAssertEqual(decision.confidence, 0.91, accuracy: 0.0001)
        XCTAssertFalse(decision.reasoning.isEmpty)

        // Two blind advocates, two cross-examinations, one verdict.
        let rounds = await exchange.roundsInOrder()
        XCTAssertEqual(rounds.count, 5)
        XCTAssertEqual(Set(rounds.prefix(2)), [.advocacy])
        XCTAssertEqual(Set(rounds.dropFirst(2).prefix(2)), [.crossExamination])
        XCTAssertEqual(rounds.last, .verdict)
    }

    /// "The winning side convinced of its accuracy is printed" — so a hedging
    /// verdict must leave the line already on screen alone.
    func test_verdictBelowMinimumConfidence_abstainsAfterDebating() async {
        let hedged = TranscriptDebate.minimumConfidence - 0.01
        let (debate, exchange) = makeDebate { request in
            guard round(of: request) == .verdict else { return happyPath(request) }
            return (200, """
                {"winner": "openai", "text": "how do I mind the schedule", \
                "language": "en", "confidence": \(hedged), "reasoning": "unsure"}
                """)
        }

        let verdict = await debate.judge(
            candidates: bothEngines, language: .ko, context: context)
        XCTAssertNil(verdict)
        let count = await exchange.count
        XCTAssertEqual(count, 5, "the debate still ran; only the conclusion was rejected")
    }

    func test_verdictExactlyAtMinimumConfidence_isAccepted() async {
        let (debate, _) = makeDebate { request in
            guard round(of: request) == .verdict else { return happyPath(request) }
            return (200, """
                {"winner": "openai", "confidence": \(TranscriptDebate.minimumConfidence), \
                "reasoning": "just convinced"}
                """)
        }
        let verdict = await debate.judge(
            candidates: bothEngines, language: .ko, context: context)
        XCTAssertEqual(verdict?.engine, .openai)
    }

    // MARK: - Failures never reach the caller

    func test_httpFailureInRoundTwo_abstainsAndNeverReachesTheVerdict() async {
        let (debate, exchange) = makeDebate { request in
            round(of: request) == .crossExamination
                ? (500, "overloaded")
                : happyPath(request)
        }

        let verdict = await debate.judge(
            candidates: bothEngines, language: .ko, context: context)
        XCTAssertNil(verdict)
        let rounds = await exchange.roundsInOrder()
        XCTAssertFalse(rounds.contains(.verdict))
    }

    func test_unparseableAdvocacy_abstainsBeforeCrossExamination() async {
        let (debate, exchange) = makeDebate { request in
            round(of: request) == .advocacy
                ? (200, "I'd rather explain in prose.")
                : happyPath(request)
        }

        let verdict = await debate.judge(
            candidates: bothEngines, language: .ko, context: context)
        XCTAssertNil(verdict)
        let rounds = await exchange.roundsInOrder()
        XCTAssertFalse(rounds.contains(.crossExamination))
        XCTAssertFalse(rounds.contains(.verdict))
    }

    func test_responseWithNoTextBlock_abstains() async {
        let (debate, _) = makeDebate { _ in (200, "") }
        let verdict = await debate.judge(
            candidates: bothEngines, language: .ko, context: context)
        XCTAssertNil(verdict)
    }

    /// The deadline is shared across all three rounds, so a slow round cannot
    /// let a later one run late. Budget is injected so this test is fast.
    func test_deadlineExceeded_abstains() async {
        let (debate, _) = makeDebate(budget: 0.05, delay: 0.4, handler: happyPath)
        let verdict = await debate.judge(
            candidates: bothEngines, language: .ko, context: context)
        XCTAssertNil(verdict)
    }

    // MARK: - Stub plumbing

    private func makeDebate(
        apiKey: String? = "sk-test",
        budget: TimeInterval = TranscriptDebate.totalBudget,
        delay: TimeInterval = 0,
        handler: @escaping @Sendable (URLRequest) -> (Int, String)
    ) -> (TranscriptDebate, Exchange) {
        let exchange = Exchange(handler: handler)
        let debate = TranscriptDebate(
            transport: { request in
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                return await exchange.perform(request)
            },
            apiKey: { apiKey },
            budget: budget)
        return (debate, exchange)
    }
}

// MARK: - Canned meeting
//
// File scope so the `@Sendable` transport closures capture no test-case state.

/// RTZR's real output when the user spoke English at it, from the session logs.
private let hangulGibberish = "하다 마이님 쬐하네"
/// What the multilingual engine heard — English, with one word wrong.
private let englishHeard = "how do I mine the schedule"

/// A debate that ends the way the incident should have: the Korean specialist
/// concedes, and the verdict repairs the generalist's single mis-heard word.
@Sendable private func happyPath(_ request: URLRequest) -> (Int, String) {
    switch round(of: request) {
    case .advocacy:
        if userText(request).contains(hangulGibberish) {
            return (200, """
                {"plausible": false, "language": "en", \
                "misheard_english": "how do I mind the schedule", \
                "argument": "The syllables spell an English phrase.", \
                "confidence": 0.18}
                """)
        }
        return (200, """
            {"plausible": true, "language": "en", "misheard_english": null, \
            "argument": "Reads as a real question about scheduling.", \
            "confidence": 0.79}
            """)

    case .crossExamination:
        if ownEngine(inCrossExamination: userText(request)) == "rtzr" {
            return (200, """
                {"concede": true, \
                "argument": "Their English explains my syllables exactly.", \
                "confidence": 0.1}
                """)
        }
        return (200, """
            {"concede": false, "argument": "Only one engine here can hear English.", \
            "confidence": 0.9}
            """)

    case .verdict:
        return (200, """
            {"winner": "openai", "text": "how do I mind the schedule", \
            "language": "en", "confidence": 0.91, \
            "reasoning": "RTZR conceded; mine/mind is a single mis-hearing."}
            """)

    case nil:
        return (400, "unrecognized system prompt")
    }
}

/// Serializes the recording so parallel rounds can share one stub.
private actor Exchange {
    private var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)

    init(handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        self.handler = handler
    }

    func perform(_ request: URLRequest) -> (Data, URLResponse) {
        requests.append(request)
        let (status, text) = handler(request)
        return (messagesReply(text), httpResponse(status))
    }

    var count: Int { requests.count }

    func roundsInOrder() -> [TranscriptDebate.Round?] { requests.map(round(of:)) }
}

// MARK: - Wire helpers

private func httpResponse(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.anthropic.com/v1/messages")!,
        statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// A non-streaming Messages response carrying one text block.
private func messagesReply(_ text: String) -> Data {
    let body: [String: Any] = [
        "id": "msg_test",
        "type": "message",
        "role": "assistant",
        "content": text.isEmpty ? [] : [["type": "text", "text": text]],
    ]
    return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
}

private func requestBody(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return json
}

private func systemText(_ request: URLRequest) -> String {
    guard let system = requestBody(request)["system"] as? [[String: Any]],
          let text = system.first?["text"] as? String
    else { return "" }
    return text
}

private func userText(_ request: URLRequest) -> String {
    guard let messages = requestBody(request)["messages"] as? [[String: Any]],
          let content = messages.first?["content"] as? String
    else { return "" }
    return content
}

/// Which round a request belongs to, identified by its byte-stable system
/// prompt — no test-only header on a production request.
private func round(of request: URLRequest) -> TranscriptDebate.Round? {
    let text = systemText(request)
    return TranscriptDebate.Round.allCases.first { $0.systemPrompt == text }
}

/// Whose turn a cross-examination prompt belongs to. Both transcripts appear in
/// a round-2 prompt, so the discriminator is which engine sits under YOUR
/// POSITION.
private func ownEngine(inCrossExamination prompt: String) -> String? {
    guard let mine = prompt.range(of: "YOUR POSITION") else { return nil }
    let tail = prompt[mine.upperBound...]
    let block = tail.range(of: "RIVAL POSITION")
        .map { String(tail[..<$0.lowerBound]) } ?? String(tail)
    for engine in STTEngine.allCases where block.contains("Engine: \(engine.rawValue)") {
        return engine.rawValue
    }
    return nil
}
