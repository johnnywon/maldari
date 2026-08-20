import Foundation

/// OpenRouter streaming translator, over the OpenAI-compatible
/// chat-completions endpoint. Lets a meeting run on any model OpenRouter
/// serves, without a second app build.
///
/// Deliberately a sibling of `ClaudeTranslationService` rather than a
/// generalisation of it. The two wire formats agree on almost nothing — where
/// the system prompt lives, the delta shape, the stream terminator, the error
/// envelope — so folding them into one parser would produce a branchy mess in
/// which a provider-specific bug is invisible. What they DO share (the prompt
/// text, the retry rule, the timeout budget) is either extracted
/// (`TranslationPrompt`) or mirrored here on purpose.
final class OpenRouterTranslationService: Translating {
    private static let endpoint =
        URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let modelsEndpoint =
        URL(string: "https://openrouter.ai/api/v1/models")!
    private static let keyEndpoint =
        URL(string: "https://openrouter.ai/api/v1/key")!

    /// OpenRouter attributes requests by these two headers, and a handful of
    /// upstream providers reject traffic that arrives without a referer — so
    /// they are not optional politeness, they are part of the contract.
    private static let appReferer = "https://maldari.johnnywon.com"
    private static let appTitle = "Maldari"

    /// Tight timeouts are load-bearing, for the same reason they are on the
    /// Anthropic path: an idle SSE stream stays "alive" indefinitely on
    /// keepalive pings (OpenRouter sends `: OPENROUTER PROCESSING` comment
    /// lines while a cold upstream spins up), so a byte-gap timeout alone
    /// never fires. The 60s resource cap is the real guarantee — without it a
    /// single wedged request stalls the whole translation queue, which is
    /// exactly the "translations stopped mid-meeting" bug we already shipped
    /// once.
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15   // max gap between bytes
        config.timeoutIntervalForResource = 60  // hard cap per translation
        return URLSession(configuration: config)
    }()

    private let session: URLSession

    /// Resolved per request, not captured as a `String` at init. The service
    /// is built once and lives for the app's lifetime, so a model change in
    /// Settings has to reach the *next* utterance rather than the next launch.
    private let model: () -> String

    init(
        session: URLSession = OpenRouterTranslationService.defaultSession,
        model: @escaping () -> String = { AppSettings.shared.openRouterModel }
    ) {
        self.session = session
        self.model = model
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
                        "provider": "openrouter",
                        "model": self.resolvedModel(),
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

    /// The slug to send, with an empty/whitespace setting treated as "unset"
    /// rather than passed through — OpenRouter answers a blank model with a
    /// 400, which would look like a broken key in the UI.
    private func resolvedModel() -> String {
        let slug = model().trimmingCharacters(in: .whitespacesAndNewlines)
        return slug.isEmpty ? AppSettings.defaultOpenRouterModel : slug
    }

    private func run(
        text: String,
        source: Language,
        context: [TranslationPair],
        forbidSkip: Bool,
        deliver: (String) -> Void
    ) async throws {
        guard let apiKey = Credentials.get(.openRouterAPIKey) else {
            throw TranslationServiceError.missingOpenRouterKey
        }
        let slug = resolvedModel()

        // Same shape as the Anthropic request, expressed in OpenAI terms: the
        // system prompt is message[0] instead of a top-level field, then the
        // rolling context as alternating user/assistant turns, then the new
        // utterance. Pairs arrive already oriented to this request's direction
        // — see TranscriptStore.contextPairs(before:from:).
        var messages: [[String: Any]] = [
            ["role": "system",
             "content": TranslationPrompt.system(from: source, forbidSkip: forbidSkip)],
        ]
        for pair in context {
            messages.append(["role": "user", "content": pair.source])
            messages.append(["role": "assistant", "content": pair.target])
        }
        messages.append(["role": "user", "content": text])

        let body: [String: Any] = [
            "model": slug,
            // 512 matches the Anthropic path. One utterance never needs more,
            // and the cap is also the backstop against a model that ignores
            // the "output only the translation" rule and starts explaining.
            "max_tokens": 512,
            "stream": true,
            "messages": messages,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.appReferer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(Self.appTitle, forHTTPHeaderField: "X-Title")
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
                "provider": "openrouter",
                "model": slug,
                "body": String(errorBody.prefix(500)),
                "source_prefix": String(text.prefix(20)),
            ])
            throw TranslationServiceError.apiError(http.statusCode, errorBody)
        }

        // SSE: "data: {json}" frames, terminated by "data: [DONE]". Lines
        // starting with ":" are keepalive comments, not payload. The prefix is
        // matched without the space and then trimmed because the space after
        // "data:" is optional in the SSE spec and some upstreams omit it.
        for try await line in bytes.lines {
            if line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // A mid-stream failure (upstream provider died, moderation hit)
            // arrives as an error object inside a 200 stream, so it has to be
            // caught here rather than by the status check above.
            if let apiError = json["error"] as? [String: Any] {
                let message = apiError["message"] as? String ?? "stream error"
                DiagnosticLog.shared.error("translate", "stream_error", [
                    "provider": "openrouter",
                    "model": slug,
                    "message": String(message.prefix(300)),
                ])
                throw TranslationServiceError.apiError(
                    (apiError["code"] as? NSNumber)?.intValue ?? -1, message)
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first else { continue }
            // Text lives in delta.content while streaming. Reasoning models
            // also emit delta.reasoning, which is NOT translation output and
            // must never reach the transcript.
            if let delta = choice["delta"] as? [String: Any],
               let chunk = delta["content"] as? String,
               !chunk.isEmpty {
                deliver(chunk)
            }
        }
    }

    /// Cheap key validation for the Settings "test connection" button.
    /// GET /key authenticates like a real request but costs nothing and needs
    /// no model slug, so it can't fail for a reason unrelated to the key.
    static func testAPIKey(_ key: String, session: URLSession = .shared) async throws {
        // A pasted key often carries a trailing newline; interpolating that
        // into the Authorization header fails as an auth error rather than as
        // anything the user could diagnose.
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: keyEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue(appReferer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(appTitle, forHTTPHeaderField: "X-Title")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranslationServiceError.apiError(
                code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Model catalogue

    /// One row of the OpenRouter catalogue, reduced to what the Settings
    /// picker shows. Prices are per 1M tokens (see `perMillion`).
    struct Model: Identifiable, Equatable, Sendable {
        /// Routing slug, e.g. "openai/gpt-4o-mini" — this is what
        /// `AppSettings.openRouterModel` stores.
        let id: String
        let name: String
        let contextLength: Int?
        /// USD per 1M prompt tokens; nil when OpenRouter didn't report a
        /// usable number (variable-priced or auto-router entries).
        let promptPrice: Double?
        let completionPrice: Double?
    }

    /// Fetch the model catalogue for the Settings picker.
    ///
    /// Only transport failures and a non-200 throw. Individual rows are parsed
    /// leniently: OpenRouter serves hundreds of models from dozens of
    /// upstreams, and one row with a missing `name` or an unparseable price
    /// must not empty the entire picker.
    static func fetchModels(session: URLSession = .shared) async throws -> [Model] {
        var request = URLRequest(url: modelsEndpoint)
        request.httpMethod = "GET"
        // The catalogue is public, so this works before a key is saved —
        // useful while the user is still setting up. When a key IS present,
        // send it so the list reflects that account's routing.
        if let key = Credentials.get(.openRouterAPIKey) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(appReferer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(appTitle, forHTTPHeaderField: "X-Title")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationServiceError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw TranslationServiceError.apiError(
                http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]]
        else {
            throw TranslationServiceError.invalidResponse
        }

        let models: [Model] = rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let pricing = row["pricing"] as? [String: Any]
            return Model(
                id: id,
                name: (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                contextLength: (row["context_length"] as? NSNumber)?.intValue,
                promptPrice: perMillion(pricing?["prompt"]),
                completionPrice: perMillion(pricing?["completion"])
            )
        }
        // Sorted by slug, which groups by vendor prefix ("anthropic/…",
        // "openai/…") — the order someone scanning the picker expects.
        return models.sorted { $0.id < $1.id }
    }

    /// OpenRouter quotes pricing as decimal *strings* in USD **per token**
    /// ("0.00000015"), so multiply by 1e6 to get the per-1M-token figure every
    /// provider's own pricing page uses. Free models report "0"; variable or
    /// unknown pricing shows up as "-1" or a non-numeric string, and those
    /// become nil rather than a bogus negative price.
    private static func perMillion(_ raw: Any?) -> Double? {
        let value: Double?
        if let text = raw as? String {
            value = Double(text)
        } else if let number = raw as? NSNumber {
            // Not documented as numeric, but tolerated in case it changes.
            value = number.doubleValue
        } else {
            value = nil
        }
        guard let value, value >= 0 else { return nil }
        return value * 1_000_000
    }
}
