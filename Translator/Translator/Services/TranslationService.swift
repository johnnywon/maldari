import Foundation

/// Protocol seam for the translation layer.
protocol Translating: AnyObject {
    /// Streams target-language tokens for one utterance, given the last
    /// finalized (source, target) pairs as rolling context.
    ///
    /// `source` and `target` are explicit rather than implied so one pipeline
    /// serves both directions: Korean guests speaking to an English operator and
    /// the reverse, in the same session.
    ///
    /// `forbidSkip` is the retry lever: when true, the translator is told it
    /// MUST produce a translation and may not emit the ∅ skip sentinel. The
    /// pipeline sets it on a second pass after the model wrongly skipped an
    /// utterance that clearly carried content.
    func streamTranslation(
        of text: String,
        from source: Language,
        to target: Language,
        context: [TranslationPair],
        forbidSkip: Bool
    ) -> AsyncThrowingStream<String, Error>
}

extension Translating {
    /// Convenience: a normal first-pass translation that allows ∅ skips.
    func streamTranslation(of text: String, from source: Language, context: [TranslationPair])
        -> AsyncThrowingStream<String, Error>
    {
        streamTranslation(of: text, from: source, to: source.other,
                          context: context, forbidSkip: false)
    }
}

/// Which service performs translation.
enum TranslationProvider: String, Equatable, Sendable, CaseIterable {
    /// Anthropic Messages API, direct. The default: keeps prompt caching (the
    /// base prompt is cached, and a meeting's cost depends on that) and avoids
    /// an extra network hop on every speculative pass.
    case anthropic
    /// OpenRouter, for picking any model it serves.
    case openRouter = "openrouter"

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude Haiku, direct)"
        case .openRouter: return "OpenRouter (choose a model)"
        }
    }
}

enum TranslationServiceError: LocalizedError {
    case missingAPIKey
    case missingOpenRouterKey
    case invalidResponse
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key not configured. Add it in Settings → API Keys."
        case .missingOpenRouterKey:
            return "OpenRouter API key not configured. Add it in Settings → API Keys."
        case .invalidResponse:
            return "Invalid response from the translation API."
        case .apiError(let code, let message):
            return "Translation API error (\(code)): \(message.prefix(200))"
        }
    }
}

/// Claude Haiku streaming translator. Raw Messages API over SSE — no SDK.
final class ClaudeTranslationService: Translating {
    static let model = "claude-haiku-4-5-20251001"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Tight timeouts are load-bearing: the SSE stream stays "alive" through
    /// Anthropic's periodic ping events even when no text is coming, so an
    /// idle timeout alone never fires. The 60s resource cap guarantees no
    /// single translation can wedge the queue for longer than that — the
    /// failure mode behind "translations stopped mid-meeting".
    ///
    /// Speculative passes get a much tighter budget: a speculative translation
    /// that takes 8s is worthless, because the sentence it was guessing at has
    /// already finished. See `speculativeSession`.
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

    func streamTranslation(
        of text: String,
        from source: Language,
        to target: Language,
        context: [TranslationPair],
        forbidSkip: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var yieldedAny = false
                let deliver: (String) -> Void = {
                    yieldedAny = true
                    continuation.yield($0)
                }
                do {
                    try await self.run(text: text, source: source, context: context,
                                       forbidSkip: forbidSkip, deliver: deliver)
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
                        "source_prefix": String(text.prefix(20)),
                        "direction": "\(source.rawValue)->\(target.rawValue)",
                    ])
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    do {
                        try await self.run(text: text, source: source, context: context,
                                           forbidSkip: forbidSkip, deliver: deliver)
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
        text: String,
        source: Language,
        context: [TranslationPair],
        forbidSkip: Bool,
        deliver: (String) -> Void
    ) async throws {
        guard let apiKey = Credentials.get(.anthropicAPIKey) else {
            throw TranslationServiceError.missingAPIKey
        }

        // Rolling context: last finalized pairs as alternating user/assistant
        // turns, then the new utterance. Pairs arrive already oriented to this
        // request's direction — see TranscriptStore.contextPairs(before:from:).
        var messages: [[String: Any]] = []
        for pair in context {
            messages.append(["role": "user", "content": pair.source])
            messages.append(["role": "assistant", "content": pair.target])
        }
        messages.append(["role": "user", "content": text])

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 512,
            "stream": true,
            "system": [
                ["type": "text",
                 "text": TranslationPrompt.system(from: source, forbidSkip: forbidSkip),
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
                "source_prefix": String(text.prefix(20)),
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
