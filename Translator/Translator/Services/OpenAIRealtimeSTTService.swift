import Foundation

enum OpenAIRealtimeError: LocalizedError {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key not configured. Add it in Settings → API Keys."
        }
    }
}

/// OpenAI Realtime transcription over WebSocket.
///
/// Every wire identifier below was checked against developers.openai.com
/// (Realtime transcription / Realtime API with WebSocket guides) rather than
/// recalled, because this API was renamed twice: the 2025 beta used
/// `transcription_session.update` plus an `input_audio_format: "pcm16"` string,
/// and both are gone. What the current docs say:
///
///   • transcription-only sessions open at
///     wss://api.openai.com/v1/realtime?intent=transcription
///     (the speech-to-speech guide's ?model=… form is for `session.type`
///     "realtime"; for transcription the model is named in session.update,
///     not the URL).
///   • the only handshake header is Authorization: Bearer. The old
///     `OpenAI-Beta: realtime=v1` header is NOT sent — Realtime went GA on
///     2025-08-28 and the beta header was dropped. Sending it is the single
///     most common cause of an instant 1006 close.
///   • configuration is `session.update` with session.type "transcription".
///   • audio is `input_audio_buffer.append` with base64 in the "audio" field.
///   • transcripts arrive as
///     conversation.item.input_audio_transcription.delta / .completed.
///
/// Two doc-level ambiguities we deliberately absorb rather than bet on:
///
///  1. The transcription guide names the `conversation.item.…` events, but the
///     out-of-band-transcription cookbook handles `input_audio_buffer.
///     transcription.delta/.completed` for the same payloads. Both name
///     families are matched below; whichever the account's API version emits,
///     we transcribe. Cheap insurance against a rename that has already
///     happened once.
///  2. The guide's own example sets `turn_detection: null` and expects the client
///     to commit each turn, which would be wrong for continuous meeting audio with
///     no turn boundaries to commit at. Asking for server VAD explicitly is ALSO
///     wrong: `gpt-live-transcribe` rejects the key, and one bad field voids the
///     whole session.update. Omitting it entirely is the answer — the server then
///     applies its own server_vad, confirmed live in `session.created`
///     (threshold 0.5, prefix_padding_ms 300, silence_duration_ms 200). See the
///     note at the omission in `configure(_:)`.
///
/// Audio format: the docs specify `{"type": "audio/pcm", "rate": 24000}` and
/// nothing else — they do NOT state bit depth, channel count, or endianness,
/// so the "24 kHz mono little-endian Int16" assumption is inherited from the
/// beta `pcm16` definition and is what AudioChunker.openAISampleRate already
/// produces. It has not been contradicted by anything in the current docs.
actor OpenAIRealtimeSTTService: Transcribing {
    nonisolated(unsafe) var onMessage: ((STTMessage) -> Void)?
    nonisolated(unsafe) var onStateChange: ((STTConnectionState) -> Void)?

    /// Low-latency live transcription model. `gpt-transcribe` is the
    /// higher-accuracy sibling, but it only emits on a manually committed turn
    /// — useless for streaming captions.
    static let model = "gpt-live-transcribe"

    private static let endpoint =
        "wss://api.openai.com/v1/realtime?intent=transcription"

    /// When non-nil, the session is locked to this language and every emitted
    /// message is stamped with it. Dual-channel capture pins the mic to English
    /// so nothing downstream has to guess: the arbiter can trust the label
    /// instead of falling back to script detection on a half-formed hypothesis.
    private let pinnedLanguage: Language?
    private let session: URLSession
    /// Diagnostics tag ("mic" / "system" / "main") so concurrent streams in
    /// dual-capture mode are distinguishable in the JSONL logs.
    private let logChannel: String

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var running = false

    // OpenAI sends no seq of its own — it identifies an in-flight utterance by
    // `item_id`, an opaque session-scoped string. So we mint the seq, and the
    // store's "mutate the partial with this seq in place" contract means every
    // delta for one item_id must map to the same number and the final must
    // reuse it. seqBase in RTZRStreamingService exists because RTZR restarts
    // seq at 0 on every dial; we get that protection for free by never
    // resetting `nextSeq` and by dropping the item map on reconnect, so a
    // post-reconnect utterance can never land on a seq the store already
    // committed (item ids from the dead session would otherwise re-alias).
    private var nextSeq = 0
    private var seqForItem: [String: Int] = [:]
    private var textForItem: [String: String] = [:]

    // Drops since the connection last received a message. resume() never
    // fails synchronously — a rejected key surfaces as an immediate receive()
    // error — so the retry budget must survive "successful" dials that die
    // instantly, or a rejected stream reconnects forever.
    private var dropsSinceLastMessage = 0

    init(
        pinnedLanguage: Language? = nil,
        logChannel: String = "main",
        session: URLSession = .shared
    ) {
        self.pinnedLanguage = pinnedLanguage
        self.logChannel = logChannel
        self.session = session
    }

    // MARK: - Lifecycle

    func start(audio: AsyncStream<Data>) async {
        running = true
        nextSeq = 0
        seqForItem = [:]
        textForItem = [:]
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

    /// Isolated to the actor, so it cannot race the receive loop. See
    /// `Transcribing.detach()`.
    func detach() {
        onMessage = nil
        onStateChange = nil
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

    // MARK: - Connection

    private func connect(isReconnect: Bool = false) async throws {
        setState(isReconnect ? .reconnecting(attempt: max(1, dropsSinceLastMessage))
                             : .connecting)
        DiagnosticLog.shared.info("ws", "connecting", [
            "engine": "openai",
            "channel": logChannel,
            "reconnect": isReconnect,
            "drops": dropsSinceLastMessage,
        ])
        guard let key = Credentials.get(.openAIAPIKey) else {
            throw OpenAIRealtimeError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()

        // item_ids are scoped to the dead session; keeping them would let a
        // fresh utterance inherit a seq the store has already finalized.
        if isReconnect {
            seqForItem = [:]
            textForItem = [:]
        }
        setState(.connected)
        DiagnosticLog.shared.info("ws", "connected", [
            "engine": "openai",
            "channel": logChannel,
            "seq_base": nextSeq,
        ])
        startReceiveLoop(on: task)
        await configure(task)
    }

    /// `session.update` — the transcription-session configuration event.
    ///
    /// Verified field-by-field against the Realtime transcription guide:
    /// session.type = "transcription";
    /// session.audio.input.format = {type: "audio/pcm", rate: 24000};
    /// session.audio.input.transcription.{model, languages}.
    ///
    /// THREE documented keys are deliberately omitted — `turn_detection` (see the
    /// note at the omission itself; the model rejects it and one bad field fails the
    /// whole update). `transcription.delay`
    /// tunes latency against word error rate, but the docs never enumerate its
    /// legal values, and an unrecognised value fails the whole session.update
    /// — which would leave us connected and permanently silent. `noise_
    /// reduction` is documented for realtime (speech-to-speech) sessions and
    /// never shown on a transcription session, so it is not sent either.
    private func configure(_ task: URLSessionWebSocketTask) async {
        var transcription: [String: Any] = ["model": Self.model]
        if let pinnedLanguage {
            // "languages" is plural and takes ISO-639-1 codes — which is
            // exactly Language.rawValue ("ko" / "en"). A one-element array is
            // the documented way to lock the session to a single language.
            transcription["languages"] = [pinnedLanguage.rawValue]
        }

        let format: [String: Any] = [
            "type": "audio/pcm",
            "rate": Int(AudioChunker.openAISampleRate),
        ]
        // NO turn_detection.
        //
        // `gpt-live-transcribe` rejects the key outright, and because one bad field
        // fails the WHOLE session.update, sending it meant the transcription model
        // was never configured: the socket connected, reported "Connected", and then
        // produced zero transcripts for the entire session. That is precisely the
        // "speaking English just hangs" symptom. Verified against the live endpoint,
        // which answers:
        //
        //   {"type":"error","error":{"message":"Turn detection is not supported for
        //    this transcription model.","code":"invalid_value",
        //    "param":"session.audio.input.turn_detection"}}
        //
        // Omitting it also gives the behaviour we wanted anyway: `session.created`
        // shows the server already applying its own server_vad (threshold 0.5,
        // prefix_padding_ms 300, silence_duration_ms 200), which segments close
        // enough to RTZR's epd_time 0.5 for the arbiter to compare like with like.
        //
        // Built in annotated steps rather than as one literal: a five-deep
        // heterogeneous dictionary literal is exactly the shape that makes the
        // type checker bail out with "expression too complex".
        let input: [String: Any] = [
            "format": format,
            "transcription": transcription,
        ]
        let sessionConfig: [String: Any] = [
            "type": "transcription",
            "audio": ["input": input],
        ]
        let event: [String: Any] = [
            "type": "session.update",
            "session": sessionConfig,
        ]
        await sendJSON(event, on: task)
        DiagnosticLog.shared.info("ws", "session_configured", [
            "engine": "openai",
            "channel": logChannel,
            "model": Self.model,
            "pinned_language": pinnedLanguage?.rawValue ?? "",
        ])
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

    // MARK: - Server events

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw): data = raw
        @unknown default: data = nil
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        // The server is talking: this connection is healthy, reset the budget.
        // Deliberately before the switch — session.created and the VAD
        // speech_started/stopped chatter prove liveness during a long silence
        // just as well as a transcript does.
        dropsSinceLastMessage = 0

        switch type {
        // Both name families for the same payload — see the type-level note on
        // the transcription guide vs. the cookbook disagreeing.
        case "conversation.item.input_audio_transcription.delta",
             "input_audio_buffer.transcription.delta":
            handleDelta(json)

        case "conversation.item.input_audio_transcription.completed",
             "input_audio_buffer.transcription.completed":
            handleCompleted(json)

        case "error":
            // Session-level failures (bad model id, rejected session.update)
            // arrive here without closing the socket, so they would otherwise
            // be invisible: we would sit "connected" and never transcribe.
            let error = json["error"] as? [String: Any]
            DiagnosticLog.shared.error("ws", "server_error", [
                "engine": "openai",
                "channel": logChannel,
                "code": error?["code"] as? String ?? "",
                "message": String((error?["message"] as? String ?? "").prefix(300)),
            ])

        default:
            break
        }
    }

    /// Delta payload: {type, item_id, content_index, delta}.
    private func handleDelta(_ json: [String: Any]) {
        guard let itemID = json["item_id"] as? String,
              let delta = json["delta"] as? String, !delta.isEmpty else { return }

        let seq = seq(for: itemID)
        // Deltas are additive fragments, per the guide ("incremental
        // transcripts as they are streamed out"). If a future API version ever
        // starts sending the cumulative transcript instead, this append is the
        // one line to change — the symptom would be visibly doubled text.
        let accumulated = (textForItem[itemID] ?? "") + delta
        textForItem[itemID] = accumulated

        emit(seq: seq, text: accumulated, isFinal: false, json: json)
    }

    /// Completed payload: {type, item_id, content_index, transcript} plus
    /// `languages` when the model reports detection (gpt-transcribe does;
    /// gpt-live-transcribe does not).
    private func handleCompleted(_ json: [String: Any]) {
        guard let itemID = json["item_id"] as? String else { return }

        // Prefer the server's authoritative transcript; fall back to the
        // accumulated deltas only if the field is missing, because a partial
        // that never finalizes strands the utterance in grey forever.
        let transcript = (json["transcript"] as? String) ?? textForItem[itemID] ?? ""
        let seq = seq(for: itemID)

        DiagnosticLog.shared.info("stt", "final", [
            "engine": "openai",
            "channel": logChannel,
            "seq": seq,
            "text": transcript,
            "confidence": confidence(from: json) ?? -1,
        ])
        emit(seq: seq, text: transcript, isFinal: true, json: json)

        // Retire the item. `nextSeq` has already moved past this seq, so the
        // next utterance gets a fresh one — this is the "bump the seq" step.
        seqForItem.removeValue(forKey: itemID)
        textForItem.removeValue(forKey: itemID)
    }

    private func emit(seq: Int, text: String, isFinal: Bool, json: [String: Any]) {
        let message = STTMessage(
            seq: seq,
            isFinal: isFinal,
            text: text,
            confidence: confidence(from: json),
            engine: .openai,
            language: pinnedLanguage ?? reportedLanguage(json)
        )
        onMessage?(message)
    }

    /// A seq that is stable for the lifetime of one utterance. Allocating
    /// lazily on first sight of an item_id means a `.completed` with no
    /// preceding delta (short utterance, or deltas lost across a reconnect)
    /// still gets its own line instead of overwriting the previous one.
    private func seq(for itemID: String) -> Int {
        if let existing = seqForItem[itemID] { return existing }
        let seq = nextSeq
        nextSeq += 1
        seqForItem[itemID] = seq
        return seq
    }

    /// The docs state plainly that gpt-live-transcribe returns no confidence
    /// scores, so this is nil in practice and the arbiter must not depend on
    /// it. Kept because `logprobs` is populated on some model/version
    /// combinations, and a real number is strictly better than a guess: mean
    /// log-probability exponentiated back into 0...1, the same shape RTZR's
    /// `confidence` has.
    private func confidence(from json: [String: Any]) -> Double? {
        guard let entries = json["logprobs"] as? [[String: Any]], !entries.isEmpty
        else { return nil }
        let values = entries.compactMap { $0["logprob"] as? Double }
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return exp(mean)
    }

    /// Language the server reported, when it reports one. Returns nil for
    /// anything that is not one of our two languages so that
    /// STTMessage.resolvedLanguage falls back to script detection rather than
    /// asserting a language the rest of the app cannot represent.
    private func reportedLanguage(_ json: [String: Any]) -> Language? {
        // "languages" (plural array) is the documented completion field;
        // "language" is accepted defensively — cheaper than a wrong label.
        let code = (json["languages"] as? [String])?.first
            ?? json["language"] as? String
        guard let code = code?.lowercased() else { return nil }
        switch code {
        // ISO-639-1 is what the docs specify; the 639-3 forms are tolerated
        // because the guide says selected 639-3 codes are also accepted for
        // the request side, and symmetry is not guaranteed.
        case "ko", "kor": return .ko
        case "en", "eng": return .en
        default: return nil
        }
    }

    // MARK: - Reconnect

    private func handleSocketDrop(_ error: Error) async {
        guard running else { return }
        dropsSinceLastMessage += 1
        DiagnosticLog.shared.warn("ws", "socket_dropped", [
            "engine": "openai",
            "channel": logChannel,
            "error": error.localizedDescription,
            "close_code": socket?.closeCode.rawValue ?? -1,
            "close_reason": socket?.closeReason
                .flatMap { String(data: $0, encoding: .utf8) } ?? "",
            "drops": dropsSinceLastMessage,
        ])
        if dropsSinceLastMessage >= 6 {
            DiagnosticLog.shared.error("ws", "gave_up", [
                "engine": "openai",
                "channel": logChannel,
                "error": error.localizedDescription,
                "drops": dropsSinceLastMessage,
            ])
            setState(.failed(error.localizedDescription))
            running = false
            return
        }

        setState(.reconnecting(attempt: dropsSinceLastMessage))
        let delay = min(30.0, pow(2.0, Double(dropsSinceLastMessage - 1)))
        DiagnosticLog.shared.info("ws", "reconnect_scheduled", [
            "engine": "openai",
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

    /// One `input_audio_buffer.append`. The docs give no acknowledgement for
    /// this event, so there is nothing to await beyond the socket write.
    private func send(_ chunk: Data) async {
        guard let socket else { return }
        await sendJSON([
            "type": "input_audio_buffer.append",
            "audio": chunk.base64EncodedString(),
        ], on: socket)
    }

    private func sendJSON(
        _ event: [String: Any],
        on task: URLSessionWebSocketTask
    ) async {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        do {
            try await task.send(.string(text))
        } catch {
            // The receive loop owns reconnection; chunks dropped during the
            // gap are acceptable for live captioning.
        }
    }

    /// `input_audio_buffer.commit` is this engine's EOS: it flushes whatever
    /// the VAD is still holding so the last sentence of a meeting finalizes
    /// instead of dying with the socket. Harmless when the buffer is empty —
    /// the server answers with an `error` event we only log.
    private func finishStream() async {
        guard let socket, socket.state == .running else { return }
        DiagnosticLog.shared.info("ws", "eos_sent", [
            "engine": "openai",
            "channel": logChannel,
        ])
        await sendJSON(["type": "input_audio_buffer.commit"], on: socket)
    }

    private func setState(_ state: STTConnectionState) {
        onStateChange?(state)
    }

    // MARK: - Key validation

    /// Cheap key validation for the Settings "test connection" button.
    /// GET /v1/models is authenticated, free, and does not spin up a realtime
    /// session — dialling the WebSocket just to check a key would bill audio
    /// minutes and take seconds to fail.
    static func testAPIKey(_ key: String, session: URLSession = .shared) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranslationServiceError.apiError(
                code, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
