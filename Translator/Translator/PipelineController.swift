import Foundation
import AppKit

/// Wires the one-way pipeline:
/// AudioCapturing → Transcribing → Translating → TranscriptStore → UI.
///
/// Owns session lifecycle (start/stop), source selection, and the bounded
/// translation queue. All published state is main-actor. Every stage logs to
/// DiagnosticLog (~/Library/Logs/Translator/) and the live transcript is
/// persisted via SessionRecorder, so a crash mid-meeting loses nothing.
///
/// A session runs a single *channel* (capture + STT stream). The channel
/// machinery stays generic, but only one runs at a time.
@MainActor
@Observable
final class PipelineController {
    let store = TranscriptStore()

    private(set) var isListening = false
    private(set) var connectionState: STTConnectionState = .idle
    private(set) var lastError: String?
    var audioSource: AudioSourceSelection = .microphone

    /// What one channel of a session is made of.
    private struct ChannelSpec {
        let selection: AudioSourceSelection
        let label: String   // diagnostics tag: "main"
    }

    private struct ActiveChannel {
        let spec: ChannelSpec
        let capture: AudioCapturing
        let transcriber: Transcribing
    }

    /// RTZR seq restarts at 0 per stream, and `Utterance.id` is the seq —
    /// each channel's ids live in their own band so two streams can't
    /// collide (the store drops duplicate ids). RTZRStreamingService's
    /// reconnect seqBase stays within a band: it offsets from the highest
    /// *service-local* seq, far below one million per session.
    static let channelIDStride = 1_000_000

    private var channels: [ActiveChannel] = []
    private var channelStates: [STTConnectionState] = []
    private let translator: Translating
    private let translationQueue = TranslationQueue(maxConcurrent: 2)
    private let recorder = SessionRecorder()
    private let settings = AppSettings.shared
    /// Guards the async window inside start() so a double-click can't spin
    /// up two captures.
    private var isStarting = false

    // Liveness telemetry, reported by the heartbeat.
    private var heartbeatTask: Task<Void, Never>?
    private let audioChunkCounter = ChunkCounter()
    private var lastSTTMessageAt: Date?

    /// Factory seams so tests can inject mocks.
    var makeCapture: (AudioSourceSelection) -> AudioCapturing = { selection in
        switch selection {
        case .microphone: return MicrophoneCaptureService()
        case .systemAudio, .process: return SystemAudioCaptureService(selection: selection)
        }
    }
    var makeTranscriber: (_ channel: String) -> Transcribing = { channel in
        RTZRStreamingService(keywords: { AppSettings.shared.keywordList }, logChannel: channel)
    }
    var credentialsCheck: () -> Bool = { Credentials.hasRTZR && Credentials.hasAnthropic }

    init(translator: Translating = ClaudeTranslationService()) {
        self.translator = translator
        store.onFinalized = { [weak self] utterance in
            self?.recorder.recordFinal(utterance)
            self?.enqueueTranslation(for: utterance)
        }
    }

    // MARK: - Session control

    func toggleListening() {
        if isListening { Task { await stop() } } else { Task { await start() } }
    }

    func start() async {
        guard !isListening, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        lastError = nil
        connectionState = .idle
        DiagnosticLog.shared.info("session", "start_requested", [
            "source": String(describing: audioSource),
        ])

        guard credentialsCheck() else {
            lastError = Credentials.hasRTZR
                ? TranslationServiceError.missingAPIKey.localizedDescription
                : RTZRError.missingCredentials.localizedDescription
            DiagnosticLog.shared.error("session", "start_blocked", ["error": lastError ?? ""])
            return
        }

        let specs = channelSpecs(for: audioSource)
        channelStates = Array(repeating: .idle, count: specs.count)
        channels = specs.enumerated().map { index, spec in
            let capture = makeCapture(spec.selection)
            let transcriber = makeTranscriber(spec.label)
            let idBase = index * Self.channelIDStride
            transcriber.onMessage = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastSTTMessageAt = Date()
                    // Shift this stream's seqs into the channel's id band so
                    // utterance ids stay unique (idBase is 0 for the single
                    // channel; the band math is kept for the generic path).
                    var namespaced = message
                    namespaced.seq += idBase
                    self.store.apply(namespaced)
                }
            }
            transcriber.onStateChange = { [weak self] state in
                Task { @MainActor [weak self] in
                    await self?.channelStateChanged(state, at: index, label: spec.label)
                }
            }
            return ActiveChannel(spec: spec, capture: capture, transcriber: transcriber)
        }

        // Start every capture before any STT stream: if one capture can't
        // start (e.g. system-audio permission missing in dual mode), abort
        // the whole session rather than silently running half-attributed.
        var audioStreams: [AsyncStream<Data>] = []
        do {
            for channel in channels {
                audioStreams.append(try await channel.capture.start())
            }
        } catch {
            lastError = error.localizedDescription
            DiagnosticLog.shared.error("session", "capture_failed", [
                "error": error.localizedDescription,
            ])
            for channel in channels { channel.capture.stop() }
            channels = []
            channelStates = []
            connectionState = .idle
            return
        }

        store.startSession()
        recorder.begin()
        isListening = true
        startHeartbeat()
        audioChunkCounter.reset()
        for (index, channel) in channels.enumerated() {
            await channel.transcriber.start(audio: counted(audioStreams[index]))
        }
    }

    func stop() async {
        guard isListening else { return }
        DiagnosticLog.shared.info("session", "stop_requested", [
            "utterances": store.utterances.count,
        ])
        heartbeatTask?.cancel()
        heartbeatTask = nil
        // Detach callbacks first so late events from the dying connections
        // can't overwrite UI state after this point.
        for channel in channels {
            channel.transcriber.onMessage = nil
            channel.transcriber.onStateChange = nil
        }
        for channel in channels {
            channel.capture.stop()    // finishes the audio stream → EOS follows
        }
        for channel in channels {
            await channel.transcriber.stop()
        }
        channels = []
        channelStates = []
        isListening = false
        recorder.end(finalSnapshotOf: store)
        // Keep a failure visible until the next start; otherwise go idle.
        if case .failed = connectionState {} else {
            connectionState = .idle
        }
    }

    private func channelSpecs(for source: AudioSourceSelection) -> [ChannelSpec] {
        [ChannelSpec(selection: source, label: "main")]
    }

    private func channelStateChanged(_ state: STTConnectionState, at index: Int, label: String) async {
        guard index < channelStates.count else { return }
        channelStates[index] = state
        connectionState = Self.mergedState(channelStates)
        if case .failed(let message) = state {
            lastError = message
            DiagnosticLog.shared.error("session", "stt_failed", [
                "error": message,
                "channel": label,
            ])
            // Tear the whole session down, or the capture keeps feeding an
            // AsyncStream nobody consumes (unbounded buffer) while the UI
            // still claims to be listening.
            await stop()
        }
    }

    /// One state for the status dot: the worst channel wins.
    nonisolated static func mergedState(_ states: [STTConnectionState]) -> STTConnectionState {
        if let failed = states.first(where: {
            if case .failed = $0 { return true } else { return false }
        }) { return failed }
        if let reconnecting = states.first(where: {
            if case .reconnecting = $0 { return true } else { return false }
        }) { return reconnecting }
        if states.contains(.connecting) { return .connecting }
        if !states.isEmpty, states.allSatisfy({ $0 == .connected }) { return .connected }
        // Mixed connected/idle (a channel not dialed yet) reads as connecting.
        if states.contains(.connected) { return .connecting }
        return .idle
    }

    func switchSource(_ source: AudioSourceSelection) {
        audioSource = source
        guard isListening else { return }
        Task {
            await stop()
            await start()
        }
    }

    // MARK: - Liveness

    /// Pass-through wrapper that counts audio chunks, so the heartbeat can
    /// tell "audio flowing but STT silent" (server problem) apart from
    /// "no audio at all" (capture problem) when a session goes quiet.
    /// The counter is shared across channels (start() resets it once).
    private func counted(_ audio: AsyncStream<Data>) -> AsyncStream<Data> {
        let counter = audioChunkCounter
        return AsyncStream { continuation in
            let task = Task {
                for await chunk in audio {
                    counter.increment()
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                self?.logHeartbeat()
            }
        }
    }

    private func logHeartbeat() {
        let chunks = audioChunkCounter.takeCount()
        let sttSilence = lastSTTMessageAt.map { Date().timeIntervalSince($0) }
        DiagnosticLog.shared.info("session", "heartbeat", [
            "state": connectionState.label,
            "channels": channels.count,
            "utterances": store.utterances.count,
            "translated": store.utterances.filter { $0.state == .translated }.count,
            "failed": store.utterances.filter { $0.state == .failed }.count,
            "queue_depth": translationQueue.depth,
            "audio_chunks_30s": chunks,
            "stt_silence_s": sttSilence.map { Int($0) } ?? -1,
        ])
        // Audio is flowing but RTZR has said nothing for 2 minutes: the
        // stream is wedged in a way the reconnect logic didn't catch.
        if let silence = sttSilence, silence > 120, chunks > 0, isListening {
            DiagnosticLog.shared.error("session", "stt_stalled", [
                "stt_silence_s": Int(silence),
                "audio_chunks_30s": chunks,
            ])
        }
    }

    // MARK: - Translation

    private func enqueueTranslation(for utterance: Utterance) {
        let translator = self.translator
        let store = self.store
        let recorder = self.recorder
        let queue = self.translationQueue
        let queuedAt = Date()
        DiagnosticLog.shared.info("translate", "queued", [
            "id": utterance.id,
            "queue_depth": queue.depth,
            "korean_chars": utterance.korean.count,
        ])
        queue.enqueue { @MainActor in
            let startedAt = Date()
            let context = store.contextPairs(before: utterance.id)
            var firstTokenAt: Date?
            // Declared out here so the catch block can log/record the partial.
            var collected = ""

            // One streaming pass into the row; `beginTranslation` resets the
            // English so a forced retry overwrites the discarded ∅ cleanly.
            @MainActor func stream(forbidSkip: Bool) async throws {
                store.beginTranslation(id: utterance.id)
                collected = ""
                for try await token in translator.streamTranslation(
                    of: utterance.korean, context: context, forbidSkip: forbidSkip)
                {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    collected += token
                    store.appendTranslation(id: utterance.id, token: token)
                }
            }

            do {
                try await stream(forbidSkip: false)
                var forced = false

                // The model emitted the skip sentinel, but the Korean clearly
                // carries content. That's the over-skip bug: re-translate once
                // with skipping forbidden rather than silently dropping a real
                // line. (Genuine short filler falls through and is dropped.)
                if TranslationFilter.isFiller(collected),
                   TranslationFilter.koreanHasSubstance(utterance.korean) {
                    forced = true
                    DiagnosticLog.shared.warn("translate", "filler_override", [
                        "id": utterance.id,
                        "korean_chars": utterance.korean.count,
                    ])
                    try await stream(forbidSkip: true)
                }

                if TranslationFilter.isFiller(collected) {
                    store.clearTranslation(id: utterance.id)
                    DiagnosticLog.shared.info("translate", "skipped_filler", [
                        "id": utterance.id,
                        "raw": String(collected.prefix(80)),
                        "forced": forced,
                    ])
                } else {
                    store.endTranslation(id: utterance.id)
                    DiagnosticLog.shared.info("translate", "completed", [
                        "id": utterance.id,
                        "wait_ms": Int(startedAt.timeIntervalSince(queuedAt) * 1000),
                        "ttft_ms": firstTokenAt.map { Int($0.timeIntervalSince(startedAt) * 1000) } ?? -1,
                        "total_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                        "english_chars": collected.count,
                        "forced": forced,
                    ])
                }
                recorder.recordTranslation(
                    id: utterance.id,
                    english: TranslationFilter.isFiller(collected) ? "" : collected,
                    failed: false)
            } catch {
                store.endTranslation(id: utterance.id, failed: true)
                DiagnosticLog.shared.error("translate", "failed", [
                    "id": utterance.id,
                    "error": error.localizedDescription,
                    "wait_ms": Int(startedAt.timeIntervalSince(queuedAt) * 1000),
                    "partial_chars": collected.count,
                ])
                recorder.recordTranslation(id: utterance.id, english: collected, failed: true)
            }
            recorder.scheduleSnapshot(of: store)
        }
    }

    // MARK: - Export

    func exportTranscript() {
        guard !store.utterances.isEmpty else { return }
        do {
            let url = try store.exportToDownloads()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// Thread-safe chunk counter shared between the audio pass-through task and
/// the main-actor heartbeat.
final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    /// Returns the count since the last call and resets it.
    func takeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        let value = count
        count = 0
        return value
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        count = 0
    }
}

/// Runs translation jobs with bounded concurrency (FIFO start order), so a
/// burst of finalized utterances drains in parallel but the pipeline never
/// floods the API. With maxConcurrent == 1 this is the original strictly
/// serial queue.
///
/// Jobs flow through an AsyncStream consumed by a single dispatcher task.
/// `enqueue` yields synchronously, so callers on one actor (the store's
/// onFinalized always fires on the main actor) get guaranteed FIFO — an
/// unstructured Task hop here would NOT preserve submission order.
final class TranslationQueue: @unchecked Sendable {
    typealias Job = @Sendable () async -> Void

    private let continuation: AsyncStream<Job>.Continuation
    private let worker: Task<Void, Never>
    private let lock = NSLock()
    private var pending = 0

    /// Jobs enqueued but not yet finished — the heartbeat's backlog gauge.
    var depth: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    init(maxConcurrent: Int = 1) {
        let (stream, continuation) = AsyncStream.makeStream(of: Job.self)
        self.continuation = continuation
        let cap = max(1, maxConcurrent)
        self.worker = Task {
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for await job in stream {
                    if running >= cap {
                        await group.next()
                        running -= 1
                    }
                    group.addTask { await job() }
                    running += 1
                }
                await group.waitForAll()
            }
        }
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }

    func enqueue(_ job: @escaping Job) {
        lock.lock()
        pending += 1
        lock.unlock()
        continuation.yield { [weak self] in
            await job()
            self?.jobFinished()
        }
    }

    /// Synchronous on purpose: NSLock's lock()/unlock() are `noasync` (an
    /// error in Swift 6 mode), so the async job wrapper above must not touch
    /// the lock directly.
    private func jobFinished() {
        lock.lock()
        pending -= 1
        lock.unlock()
    }
}
