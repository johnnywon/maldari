import Foundation

enum STTConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reconnecting(let n): return "Reconnecting (\(n))…"
        case .failed(let msg): return "Error: \(msg)"
        }
    }
}

/// Protocol seam for the STT layer. Callbacks fire on arbitrary threads;
/// the pipeline hops to the main actor.
protocol Transcribing: AnyObject {
    var onMessage: ((STTMessage) -> Void)? { get set }
    var onStateChange: ((STTConnectionState) -> Void)? { get set }
    /// Consumes the audio stream until `stop()` or the stream ends.
    func start(audio: AsyncStream<Data>) async
    func stop() async
}

enum RTZRError: LocalizedError {
    case missingCredentials
    case authFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "RTZR client ID/secret not configured. Add them in Settings → API Keys."
        case .authFailed(let code, let body):
            return "RTZR auth failed (\(code)): \(body)"
        }
    }
}

/// RTZR (vito.ai) streaming STT over WebSocket.
///
/// Endpoints verified against developers.rtzr.ai (Streaming STT → WebSocket):
///   auth   POST https://openapi.vito.ai/v1/authenticate  (form: client_id, client_secret)
///   stream wss://openapi.vito.ai/v1/transcribe:streaming?sample_rate=…&encoding=LINEAR16&…
///   binary frames carry PCM; the text frame "EOS" ends the stream;
///   responses are JSON STTMessage payloads.
actor RTZRStreamingService: Transcribing {
    nonisolated(unsafe) var onMessage: ((STTMessage) -> Void)?
    nonisolated(unsafe) var onStateChange: ((STTConnectionState) -> Void)?

    private let keywords: () -> [String]
    private let session: URLSession
    /// Diagnostics tag ("mic" / "system" / "main") so concurrent streams in
    /// dual-capture mode are distinguishable in the JSONL logs.
    private let logChannel: String

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var running = false

    // Token cache: RTZR JWTs are valid ~6h.
    private var accessToken: String?
    private var tokenExpiry: Date?

    // RTZR seq restarts at 0 on every new connection; offset keeps utterance
    // ids unique across reconnects within a session.
    private var seqBase = 0
    private var maxSeqSeen = -1

    // Drops since the connection last received a message. resume() never
    // fails synchronously — a bad token surfaces as an immediate receive()
    // error — so the retry budget must survive "successful" dials that die
    // instantly, or a rejected stream reconnects forever.
    private var dropsSinceLastMessage = 0

    init(
        keywords: @escaping () -> [String] = { [] },
        session: URLSession = .shared,
        logChannel: String = "main"
    ) {
        self.keywords = keywords
        self.session = session
        self.logChannel = logChannel
    }

    // MARK: - Lifecycle

    func start(audio: AsyncStream<Data>) async {
        running = true
        seqBase = 0
        maxSeqSeen = -1
        dropsSinceLastMessage = 0

        do {
            try await connect()
        } catch {
            setState(.failed(error.localizedDescription))
            running = false
            return
        }

        pumpTask = Task { [weak self] in
            for await chunk in audio {
                guard let self, await self.isRunning else { break }
                await self.send(chunk)
            }
            await self?.finishStream()
        }
    }

    func stop() async {
        running = false
        pumpTask?.cancel()
        pumpTask = nil
        await finishStream()
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        // No .idle emission here: the pipeline controller owns UI state on
        // stop, and a late callback would race whatever it decided to show.
    }

    private var isRunning: Bool { running }

    // MARK: - Auth

    private func token() async throws -> String {
        if let accessToken, let tokenExpiry, tokenExpiry > Date().addingTimeInterval(60) {
            return accessToken
        }
        guard let id = Credentials.get(.rtzrClientID),
              let secret = Credentials.get(.rtzrClientSecret) else {
            throw RTZRError.missingCredentials
        }
        return try await Self.authenticate(clientID: id, clientSecret: secret, session: session) {
            self.accessToken = $0
            self.tokenExpiry = $1
        }
    }

    /// Static so the Settings "test connection" button can reuse it.
    @discardableResult
    static func authenticate(
        clientID: String,
        clientSecret: String,
        session: URLSession = .shared,
        cache: ((String, Date) -> Void)? = nil
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openapi.vito.ai/v1/authenticate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RTZRError.authFailed(-1, "no response")
        }
        guard http.statusCode == 200 else {
            throw RTZRError.authFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct AuthResponse: Decodable {
            let accessToken: String
            let expireAt: Double?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expireAt = "expire_at"
            }
        }
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        let expiry = auth.expireAt.map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(5 * 3600)
        cache?(auth.accessToken, expiry)
        return auth.accessToken
    }

    // MARK: - Connection

    private func streamingURL() -> URL {
        var components = URLComponents(string: "wss://openapi.vito.ai/v1/transcribe:streaming")!
        var items = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "LINEAR16"),
            URLQueryItem(name: "model_name", value: "sommers_ko"),
            URLQueryItem(name: "domain", value: "MEETING"),
            URLQueryItem(name: "use_itn", value: "true"),
            // Smaller, faster chunks. epd_time: emit a final after 0.5s of
            // silence (the recommended floor) instead of the 0.8s default, so
            // natural pauses cut a line sooner. max_utter_duration: force a
            // final after 5s of continuous speech instead of the 12s default,
            // so run-on sentences don't sit untranslated in grey. Both are
            // RuntimeStreamConfig fields accepted as streaming query params.
            URLQueryItem(name: "epd_time", value: "0.5"),
            URLQueryItem(name: "max_utter_duration", value: "5"),
        ]
        let words = keywords().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !words.isEmpty {
            // WebSocket keyword boosting: one comma-separated param, "word" or "word:score".
            items.append(URLQueryItem(name: "keywords", value: words.joined(separator: ",")))
        }
        components.queryItems = items
        return components.url!
    }

    private func connect(isReconnect: Bool = false) async throws {
        setState(isReconnect ? .reconnecting(attempt: max(1, dropsSinceLastMessage)) : .connecting)
        DiagnosticLog.shared.info("ws", "connecting", [
            "channel": logChannel,
            "reconnect": isReconnect,
            "drops": dropsSinceLastMessage,
        ])
        let bearer = try await token()
        var request = URLRequest(url: streamingURL())
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        if isReconnect {
            seqBase = maxSeqSeen + 1
        }
        setState(.connected)
        DiagnosticLog.shared.info("ws", "connected", [
            "channel": logChannel,
            "seq_base": seqBase,
        ])
        startReceiveLoop(on: task)
    }

    private func startReceiveLoop(on task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await self?.handle(message)
                } catch {
                    await self?.handleSocketDrop(error)
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw): data = raw
        @unknown default: data = nil
        }
        guard let data, var stt = try? STTMessage.decode(data) else { return }
        // The server is talking: this connection is healthy, reset the budget.
        dropsSinceLastMessage = 0
        stt.seq += seqBase
        maxSeqSeen = max(maxSeqSeen, stt.seq)
        if stt.isFinal {
            DiagnosticLog.shared.info("stt", "final", [
                "channel": logChannel,
                "seq": stt.seq,
                "text": stt.bestText ?? "",
                "confidence": stt.alternatives.first?.confidence ?? -1,
            ])
        }
        onMessage?(stt)
    }

    private func handleSocketDrop(_ error: Error) async {
        guard running else { return }
        dropsSinceLastMessage += 1
        DiagnosticLog.shared.warn("ws", "socket_dropped", [
            "channel": logChannel,
            "error": error.localizedDescription,
            "close_code": socket?.closeCode.rawValue ?? -1,
            "close_reason": socket?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "",
            "drops": dropsSinceLastMessage,
        ])
        if dropsSinceLastMessage >= 6 {
            DiagnosticLog.shared.error("ws", "gave_up", [
                "channel": logChannel,
                "error": error.localizedDescription,
                "drops": dropsSinceLastMessage,
            ])
            setState(.failed(error.localizedDescription))
            running = false
            return
        }
        // After a repeat drop the cached token is a prime suspect — re-auth.
        if dropsSinceLastMessage >= 2 { accessToken = nil }

        setState(.reconnecting(attempt: dropsSinceLastMessage))
        let delay = min(30.0, pow(2.0, Double(dropsSinceLastMessage - 1)))
        DiagnosticLog.shared.info("ws", "reconnect_scheduled", [
            "channel": logChannel,
            "delay_s": delay,
        ])
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard running else { return }
        do {
            try await connect(isReconnect: true)
        } catch {
            // Bounded: each pass increments dropsSinceLastMessage (max 6).
            await handleSocketDrop(error)
        }
    }

    // MARK: - Sending

    private func send(_ chunk: Data) async {
        guard let socket else { return }
        do {
            try await socket.send(.data(chunk))
        } catch {
            // The receive loop owns reconnection; dropped chunks during the
            // gap are acceptable for live captioning.
        }
    }

    private func finishStream() async {
        guard let socket, socket.state == .running else { return }
        DiagnosticLog.shared.info("ws", "eos_sent", ["channel": logChannel])
        try? await socket.send(.string("EOS"))
    }

    private func setState(_ state: STTConnectionState) {
        onStateChange?(state)
    }
}
