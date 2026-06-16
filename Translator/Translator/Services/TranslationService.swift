import Foundation

/// Protocol seam for the translation layer.
protocol Translating: AnyObject {
    /// Streams English tokens for one Korean utterance, given the last
    /// finalized (Korean, English) pairs as rolling context.
    ///
    /// `forbidSkip` is the retry lever: when true, the translator is told it
    /// MUST produce a translation and may not emit the ∅ skip sentinel. The
    /// pipeline sets it on a second pass after the model wrongly skipped an
    /// utterance that clearly carried content.
    func streamTranslation(of korean: String, context: [TranslationPair], forbidSkip: Bool)
        -> AsyncThrowingStream<String, Error>
}

extension Translating {
    /// Convenience: a normal first-pass translation that allows ∅ skips.
    func streamTranslation(of korean: String, context: [TranslationPair])
        -> AsyncThrowingStream<String, Error>
    {
        streamTranslation(of: korean, context: context, forbidSkip: false)
    }
}

enum TranslationServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key not configured. Add it in Settings → API Keys."
        case .invalidResponse:
            return "Invalid response from the translation API."
        case .apiError(let code, let message):
            return "Anthropic API error (\(code)): \(message.prefix(200))"
        }
    }
}

/// Claude Haiku streaming translator. Raw Messages API over SSE — no SDK.
final class ClaudeTranslationService: Translating {
    static let model = "claude-haiku-4-5-20251001"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static let basePrompt = """
        You are a professional simultaneous interpreter translating Korean business \
        speech into English in real time for a live meeting transcript.

        OUTPUT RULES — NO EXCEPTIONS:
        - Output ONLY the English translation. No acknowledgements, no preamble, \
        no explanations, no quotation marks around the output.
        - If the input is already English, output it unchanged.
        - If the input is a fragment, translate it as a fragment.
        - Real-time speech is disfluent: stutters, repeated words, mid-sentence \
        그 / 뭐 / 이제, and false starts that still reach a point are NORMAL and \
        DO carry meaning. Translate them in full. Filler at the start or end of \
        an utterance never makes the whole utterance skippable.
        - Output the skip marker ∅ ONLY when the ENTIRE utterance is nothing but \
        fillers or acknowledgements with zero information — a bare 어 / 음 / 그 / \
        응 / 으흠, or a lone 네 / 예 / 네네. Nothing longer qualifies. When you are \
        unsure whether to skip, TRANSLATE: a rough line beats a dropped one. \
        Never describe the input or emit placeholders like "(no output)" — ∅ is \
        the only skip marker, and only for pure filler.

        FIDELITY:
        - Preserve hedging and commitment level exactly. 검토해보겠습니다 = \
        "we'll look into it" — never "we will do it". 할 수 있을 것 같습니다 = \
        "I think we should be able to" — never "we can".
        - Korean drops subjects; resolve them from the conversation context \
        provided in earlier turns.
        - 존댓말 renders as natural professional English, not stiff literal honorifics.

        Numbers, dates, company names, product names, and people's names pass through.
        """

    /// Appended on a forced retry. The pipeline only sets this after the model
    /// emitted ∅ for an utterance that clearly carried content — so here we
    /// revoke the skip option entirely. Kept as a separate suffix (not woven
    /// into basePrompt) so the cached base prompt stays byte-identical across
    /// normal calls and keeps hitting the prompt cache.
    static let forceTranslateSuffix = """


        OVERRIDE: This line was flagged as containing real, translatable \
        content. Translate it IN FULL. Do NOT output ∅ or any skip marker for \
        any reason. If the speech is disfluent or fragmentary, render its \
        meaning as best you can — never drop it.
        """

    /// User glossary lives in defaults (Settings → Translation), never in
    /// code, so meeting-specific vocabulary stays out of the public repo.
    /// Read via UserDefaults directly: this is called off the main actor and
    /// UserDefaults is thread-safe.
    static func systemPrompt(glossary: String? = nil, forbidSkip: Bool = false) -> String {
        let stored = glossary
            ?? UserDefaults.standard.string(forKey: "translationGlossary")
            ?? AppSettings.defaultGlossary
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = basePrompt
        if !trimmed.isEmpty {
            prompt += "\n\nGLOSSARY (use exactly these renderings):\n" + trimmed
        }
        if forbidSkip { prompt += forceTranslateSuffix }
        return prompt
    }

    /// Tight timeouts are load-bearing: the SSE stream stays "alive" through
    /// Anthropic's periodic ping events even when no text is coming, so an
    /// idle timeout alone never fires. The 60s resource cap guarantees no
    /// single translation can wedge the (serialized) queue for longer than
    /// that — the failure mode behind "translations stopped mid-meeting".
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15   // max gap between bytes
        config.timeoutIntervalForResource = 60  // hard cap per translation
        return URLSession(configuration: config)
    }()

    private let session: URLSession

    init(session: URLSession = ClaudeTranslationService.defaultSession) {
        self.session = session
    }

    func streamTranslation(of korean: String, context: [TranslationPair], forbidSkip: Bool)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                var yieldedAny = false
                let deliver: (String) -> Void = {
                    yieldedAny = true
                    continuation.yield($0)
                }
                do {
                    try await self.run(korean: korean, context: context, forbidSkip: forbidSkip, deliver: deliver)
                    continuation.finish()
                } catch {
                    // Retry once, but only if nothing was emitted yet —
                    // retrying a half-streamed response would duplicate text.
                    guard !yieldedAny, !Task.isCancelled else {
                        continuation.finish(throwing: error)
                        return
                    }
                    DiagnosticLog.shared.warn("translate", "retrying", [
                        "error": error.localizedDescription,
                        "korean_prefix": String(korean.prefix(20)),
                    ])
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    do {
                        try await self.run(korean: korean, context: context, forbidSkip: forbidSkip, deliver: deliver)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        korean: String,
        context: [TranslationPair],
        forbidSkip: Bool,
        deliver: (String) -> Void
    ) async throws {
        guard let apiKey = Credentials.get(.anthropicAPIKey) else {
            throw TranslationServiceError.missingAPIKey
        }

        // Rolling context: last finalized pairs as alternating user/assistant
        // turns, then the new utterance.
        var messages: [[String: Any]] = []
        for pair in context {
            messages.append(["role": "user", "content": pair.korean])
            messages.append(["role": "assistant", "content": pair.english])
        }
        messages.append(["role": "user", "content": korean])

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 512,
            "stream": true,
            "system": [
                ["type": "text",
                 "text": Self.systemPrompt(forbidSkip: forbidSkip),
                 "cache_control": ["type": "ephemeral"]]
            ],
            "messages": messages,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationServiceError.invalidResponse
        }
        guard http.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            DiagnosticLog.shared.error("translate", "http_error", [
                "status": http.statusCode,
                "body": String(errorBody.prefix(500)),
                "korean_prefix": String(korean.prefix(20)),
            ])
            throw TranslationServiceError.apiError(http.statusCode, errorBody)
        }

        // SSE: each event is "event: …\ndata: {json}\n\n". We only need the
        // data lines; text arrives as content_block_delta / text_delta.
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    deliver(text)
                }
            case "message_stop":
                return
            case "error":
                let message = (json["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                DiagnosticLog.shared.error("translate", "stream_error", [
                    "message": String(message.prefix(300)),
                ])
                throw TranslationServiceError.apiError(-1, message)
            default:
                break
            }
        }
    }

    /// Cheap key validation for the Settings "test connection" button —
    /// count_tokens is free and authenticates like a real request.
    static func testAPIKey(_ key: String, session: URLSession = .shared) async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "ping"]],
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranslationServiceError.apiError(code, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
