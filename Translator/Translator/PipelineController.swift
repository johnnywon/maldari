import Foundation
import AppKit

/// Wires the pipeline:
/// AudioCapturing → Transcribing → (arbitration) → Translating → TranscriptStore → UI.
///
/// Owns session lifecycle (start/stop), source selection, capture mode, the
/// bounded translation queue, and the speculative translation loop. All published
/// state is main-actor. Every stage logs to DiagnosticLog
/// (~/Library/Logs/Maldari/) and the live transcript is persisted via
/// SessionRecorder, so a crash mid-meeting loses nothing.
///
/// A session runs one *channel* per (audio source, STT engine) pair. In
/// `koreanOnly` that is a single RTZR channel — the original behaviour. In
/// bidirectional modes there are two, and `ArbitrationCoordinator` or the channel's
/// pinned language decides what reaches the store.
@MainActor
@Observable
final class PipelineController {
    let store = TranscriptStore()

    private(set) var isListening = false
    private(set) var connectionState: STTConnectionState = .idle
    private(set) var lastError: String?
    var audioSource: AudioSourceSelection = .microphone

    /// Smoothed input level, 0...1, for the Presentation header's meter. Zero
    /// when not listening. Smoothed because a raw per-chunk RMS at 10 Hz reads as
    /// a strobe rather than a level.
    private(set) var audioLevel: Float = 0

    /// What one channel of a session is made of.
    private struct ChannelSpec {
        let selection: AudioSourceSelection
        let label: String            // diagnostics tag
        let engine: STTEngine
        /// Non-nil when the channel's language is known by construction (dual
        /// mode) rather than detected.
        let pinnedLanguage: Language?
        let sampleRate: Double
        let role: ChannelRole
    }

    /// How a channel's messages reach the store.
    private enum ChannelRole {
        /// Straight through — the only engine on this audio, or a dual-mode
        /// channel whose direction is already known.
        case direct
        /// Owns utterance boundaries and the hypothesis line.
        case segmenter
        /// Competes for the text of the segmenter's finals; never reaches the
        /// store directly.
        case challenger
    }

    private struct ActiveChannel {
        let spec: ChannelSpec
        let capture: AudioCapturing
        let transcriber: Transcribing
    }

    /// Each channel's utterance ids live in their own band so two streams can't
    /// collide (the store drops duplicate ids). RTZRStreamingService's reconnect
    /// seqBase stays within a band: it offsets from the highest *service-local*
    /// seq, far below one million per session.
    static let channelIDStride = 1_000_000

    // MARK: - Speculative translation tuning
    //
    // Untuned constants. They want adjusting against real meeting audio; the
    // numbers below are a starting point chosen so a normal sentence fires
    // roughly 4–6 passes rather than 20.

    /// Minimum gap between speculative passes for one utterance.
    static let speculativeMinInterval: TimeInterval = 0.22
    /// Korean source must grow this many characters before another pass.
    static let speculativeKoreanGrowth = 6
    /// English source must grow this many characters before another pass.
    static let speculativeEnglishGrowth = 14
    /// Below this length a hypothesis is too short to translate usefully.
    static let speculativeMinLength = 4

    private var channels: [ActiveChannel] = []
    private var channelStates: [STTConnectionState] = []
    private let translator: Translating
    private let judge: TranscriptJudging
    private let translationQueue = TranslationQueue(maxConcurrent: 2)
    private let recorder = SessionRecorder()
    private let settings = AppSettings.shared
    private var coordinator: ArbitrationCoordinator?
    /// Guards the async window inside start() so a double-click can't spin
    /// up two captures.
    private var isStarting = false
    /// Restart coalescing — see `restartIfListening()`.
    private var restartInFlight = false
    private var restartPending = false

    /// True while a stop() is between its first await and its last.
    ///
    /// `isListening` is cleared at the top of stop() (so a second stop cannot
    /// dismantle a concurrent start), which means every Start control flips its
    /// label to "Start" the moment teardown BEGINS — actively inviting a second
    /// click during the up-to-5s `translationQueue.drain()`. start() waits this out
    /// rather than interleaving with it.
    private var isStopping = false

    /// Bumped at the top of every start() and stop(). Any lifecycle operation that
    /// suspends re-checks it before touching session state, and abandons its work
    /// if another operation has taken over.
    ///
    /// `isListening` / `isStarting` alone were not enough. stop() used to clear
    /// `isListening` only AFTER awaiting `transcriber.detach()` and
    /// `transcriber.stop()` (which itself awaits an EOS frame), so a second stop()
    /// entering during that window passed the same guard. With `switchSource` and
    /// `toggleListening` both spawning bare `Task { await stop(); await start() }`,
    /// a double-click on the source button had the second stop() resume *after* the
    /// first start() had already installed new channels — and tear down the session
    /// that had just been built, leaving captures running with no owner.
    private var lifecycle = 0

    // Liveness telemetry, reported by the heartbeat.
    private var heartbeatTask: Task<Void, Never>?
    private let audioChunkCounter = ChunkCounter()
    private var lastSTTMessageAt: Date?

    /// Per-hypothesis speculative translation bookkeeping, keyed by partial seq.
    private struct SpeculationState {
        var revision = 0
        var lastFiredAt = Date.distantPast
        var lastFiredLength = 0
        var inFlight: Task<Void, Never>?
    }
    private var speculations: [Int: SpeculationState] = [:]

    /// Factory seams so tests can inject mocks.
    var makeCapture: (AudioSourceSelection, Double) -> AudioCapturing = { selection, sampleRate in
        switch selection {
        case .microphone:
            return MicrophoneCaptureService(sampleRate: sampleRate)
        case .systemAudio, .process:
            return SystemAudioCaptureService(selection: selection, sampleRate: sampleRate)
        }
    }
    var makeTranscriber: (_ engine: STTEngine, _ pinned: Language?, _ channel: String) -> Transcribing = {
        engine, pinned, channel in
        switch engine {
        case .rtzr:
            // Read UserDefaults, not AppSettings.shared: this closure is invoked from
            // the transcriber actor's executor, and AppSettings is a non-Sendable
            // @Observable mutated on the main actor. UserDefaults is thread-safe and
            // holds the same value.
            return RTZRStreamingService(
                keywords: {
                    let raw = UserDefaults.standard.string(forKey: "rtzrKeywords") ?? ""
                    return raw.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                },
                logChannel: channel)
        case .openai:
            return OpenAIRealtimeSTTService(pinnedLanguage: pinned, logChannel: channel)
        }
    }
    /// Which engine transcribes English.
    ///
    /// OpenAI Realtime, and only that: RTZR runs a Korean-only model. An on-device
    /// Apple recognizer was built and verified as a no-key alternative and then
    /// removed on request, so bidirectional capture requires an OpenAI key.
    static func englishEngine() -> STTEngine { .openai }

    var credentialsCheck: () -> Bool = {
        // The TRANSLATION key depends on the selected provider. Demanding Anthropic
        // unconditionally meant a user who had switched Settings → Translation to
        // OpenRouter, and never held an Anthropic key, could not start a session at
        // all — with an error naming the wrong service.
        let settings = AppSettings.shared
        let hasTranslator = switch settings.translationProvider {
        case .anthropic: Credentials.hasAnthropic
        case .openRouter: Credentials.hasOpenRouter
        }
        return Credentials.satisfies(settings.captureMode) && hasTranslator
    }

    init(
        translator: Translating = RoutingTranslationService(),
        judge: TranscriptJudging = TranscriptDebate()
    ) {
        self.translator = translator
        self.judge = judge
        store.onFinalized = { [weak self] utterance in
            self?.handleFinalized(utterance)
        }
        store.onPartialUpdated = { [weak self] partial in
            self?.considerSpeculation(for: partial)
        }
    }

    // MARK: - Session control

    func toggleListening() {
        if isListening { Task { await stop() } } else { Task { await start() } }
    }

    func start() async {
        guard !isListening, !isStarting else { return }
        // Let an in-flight teardown finish first. Racing it meant the old stop(),
        // on resuming from its drain, called recorder.end() against the NEW
        // session — writing an empty transcript.md, uploading a finalized payload
        // under the new session id, and closing its file handle, after which every
        // write no-opped on the nil guard. The whole second meeting was absent from
        // disk and the cloud while the UI showed a normal live transcript.
        if isStopping {
            let waitUntil = Date().addingTimeInterval(6)
            while isStopping, Date() < waitUntil {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard !isListening, !isStarting else { return }
        }
        isStarting = true
        lifecycle += 1
        let token = lifecycle
        defer { isStarting = false }
        lastError = nil
        connectionState = .idle
        let mode = settings.captureMode
        DiagnosticLog.shared.info("session", "start_requested", [
            "source": String(describing: audioSource),
            "capture_mode": mode.rawValue,
            "speculative": settings.speculativeTranslation,
            "provider": settings.translationProvider.rawValue,
        ])

        guard credentialsCheck() else {
            lastError = Self.missingCredentialMessage(for: mode)
            DiagnosticLog.shared.error("session", "start_blocked", ["error": lastError ?? ""])
            return
        }

        let specs = channelSpecs(for: audioSource, mode: mode)
        channelStates = Array(repeating: .idle, count: specs.count)

        // Bidirectional-single needs a coordinator to reconcile the two engines.
        // Every other mode's channels know their own direction.
        coordinator = specs.contains { $0.role == .segmenter } ? ArbitrationCoordinator(judge: judge) : nil
        coordinator?.onResolved = { [weak self] message in
            self?.store.apply(message)
        }
        coordinator?.onCorrected = { [weak self] id, text, language in
            self?.handleArbitrationCorrection(id: id, text: text, language: language)
        }
        // Fires after any judge has ruled, so a transcript is only promoted to the
        // record once nothing can still change it. Confirming inside onResolved
        // instead would mark it final while a correction was in flight.
        coordinator?.onArbitrationComplete = { [weak self] id in
            self?.store.confirmSource(id: id)
        }

        channels = specs.enumerated().map { index, spec in
            let capture = makeCapture(spec.selection, spec.sampleRate)
            let transcriber = makeTranscriber(spec.engine, spec.pinnedLanguage, spec.label)
            let idBase = index * Self.channelIDStride
            transcriber.onMessage = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastSTTMessageAt = Date()
                    // Shift this stream's seqs into the channel's id band so
                    // utterance ids stay unique across channels.
                    var namespaced = message
                    namespaced.seq += idBase
                    namespaced.engine = spec.engine
                    if let pinned = spec.pinnedLanguage { namespaced.language = pinned }
                    self.route(namespaced, role: spec.role)
                }
            }
            transcriber.onStateChange = { [weak self] state in
                Task { @MainActor [weak self] in
                    await self?.channelStateChanged(state, at: index, label: spec.label)
                }
            }
            // Only the first channel drives the level meter — two meters averaged
            // would read lower than either source actually is.
            if index == 0 { attachLevelMeter(to: capture) }
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
            coordinator = nil
            connectionState = .idle
            return
        }

        sessionEpoch += 1
        translationGeneration.removeAll()
        // Cancel before dropping: clearing the dictionary alone orphaned the tasks,
        // which then kept streaming into the store of a session that had just been
        // wiped.
        for state in speculations.values { state.inFlight?.cancel() }
        speculations.removeAll()
        // Another lifecycle operation took over while captures were starting.
        // Publishing now would install channels nobody owns.
        guard token == lifecycle else {
            for channel in channels { channel.capture.stop() }
            channels = []
            channelStates = []
            coordinator = nil
            DiagnosticLog.shared.info("session", "start_abandoned", ["token": token])
            return
        }

        store.startSession()
        recorder.begin()
        coordinator?.reset()
        speculations.removeAll()
        isListening = true
        // Reset before the heartbeat can read it. It used to persist across
        // sessions, so the first heartbeat of a new meeting reported silence since
        // the PREVIOUS one — real logs show `stt_silence_s: 6490` and a spurious
        // `stt_stalled` error 30 seconds into a healthy session.
        lastSTTMessageAt = Date()
        startHeartbeat()
        audioChunkCounter.reset()
        // Dial every engine CONCURRENTLY.
        //
        // This was a sequential `for … await` loop, which made one slow engine a
        // single point of failure for all of them. Observed live: the OpenAI
        // channel's handshake blocked inside `Credentials.get` behind a modal
        // keychain-ACL dialog, and because RTZR was next in line it never attempted
        // to connect at all — a bidirectional session came up with zero engines and
        // sat on "connecting" indefinitely. Even with no dialog, serial dialing adds
        // each handshake's latency to the next one's start.
        //
        // The ownership token is re-checked inside each task rather than once per
        // iteration: a channel can fail its handshake synchronously and drive
        // channelStateChanged -> stop() while its siblings are still connecting, and
        // dialing into a dead session leaves WebSockets running with nothing left to
        // shut them down.
        let dialing = channels
        let streams = audioStreams.map { counted($0) }
        await withTaskGroup(of: Void.self) { group in
            for (index, channel) in dialing.enumerated() {
                group.addTask { @MainActor [weak self] in
                    guard let self, token == self.lifecycle else {
                        DiagnosticLog.shared.warn("session", "start_aborted_mid_dial", [
                            "channel": channel.spec.label,
                        ])
                        await channel.transcriber.detach()
                        channel.capture.stop()
                        await channel.transcriber.stop()
                        return
                    }
                    await channel.transcriber.start(audio: streams[index])
                }
            }
        }
    }

    func stop() async {
        guard isListening else { return }
        // Cleared BEFORE the first await, not after: leaving it true across the
        // awaits below let a second stop() pass this very guard and then tear down
        // whatever a concurrent start() had built in the meantime.
        isListening = false
        isStopping = true
        defer { isStopping = false }
        lifecycle += 1
        let token = lifecycle
        DiagnosticLog.shared.info("session", "stop_requested", [
            "utterances": store.utterances.count,
        ])
        heartbeatTask?.cancel()
        heartbeatTask = nil
        // Detach callbacks first so late events from the dying connections can't
        // overwrite UI state after this point. Via `detach()` rather than nilling
        // the properties from here: on the actor implementations those are
        // `nonisolated(unsafe)` and their receive loops read them concurrently, so
        // a main-actor write is a genuine data race with the read.
        // Snapshot once. Re-reading `self.channels` between phases meant a
        // concurrent start() that had already assigned its new channels got them
        // detached and stopped by this teardown — dismantled while still under
        // construction.
        let dying = channels
        for channel in dying {
            await channel.transcriber.detach()
        }
        for channel in dying {
            channel.capture.stop()    // finishes the audio stream → EOS follows
        }
        for channel in dying {
            await channel.transcriber.stop()
        }
        for state in speculations.values { state.inFlight?.cancel() }
        speculations.removeAll()
        // A start() may have overtaken us across the awaits above. Its channels
        // and recorder are not ours to clear.
        guard token == lifecycle else {
            DiagnosticLog.shared.info("session", "stop_superseded", ["token": token])
            return
        }
        channels = []
        channelStates = []
        coordinator = nil
        audioLevel = 0
        // Let in-flight translations land BEFORE the recorder closes its files.
        // The last sentence of a meeting is typically still streaming when the
        // operator hits Stop; without this it renders on screen and is then
        // dropped by the recorder's closed-handle guards, leaving the saved
        // transcript short of what everyone just watched appear.
        await translationQueue.drain()
        // drain() suspends — up to 5s, and it genuinely does suspend, because the
        // last sentence still streaming is the whole reason it exists. The token
        // check above covers the detach/stop awaits but NOT this one, so it has to
        // be re-checked here: without it a session started during the drain has its
        // recorder closed and its transcript overwritten by this stop().
        guard token == lifecycle else {
            DiagnosticLog.shared.info("session", "stop_superseded_during_drain", [
                "token": token,
            ])
            return
        }
        recorder.end(finalSnapshotOf: store)
        // Keep a failure visible until the next start; otherwise go idle.
        if case .failed = connectionState {} else {
            connectionState = .idle
        }
    }

    // MARK: - Channel layout

    private func channelSpecs(for source: AudioSourceSelection, mode: CaptureMode) -> [ChannelSpec] {
        switch mode {
        case .koreanOnly:
            return [ChannelSpec(
                selection: source, label: "main", engine: .rtzr,
                pinnedLanguage: .ko, sampleRate: AudioChunker.rtzrSampleRate,
                role: .direct)]

        case .bidirectionalSingle:
            // Both engines on the same audio, at their own sample rates — which
            // means two captures of one source, since one capture cannot emit two
            // rates. The English engine segments (it is the only one valid for both
            // languages); RTZR challenges the text.
            let english = Self.englishEngine()
            return [
                ChannelSpec(
                    selection: source, label: "segmenter", engine: english,
                    pinnedLanguage: nil, sampleRate: Self.sampleRate(for: english),
                    role: .segmenter),
                // The challenger is deliberately NOT pinned to Korean even though
                // RTZR only runs a Korean model. Pinning would stamp `language:
                // .ko` onto its transcript of English speech, telling the arbiter
                // "RTZR is confident this is Korean" when what RTZR actually
                // produced is Hangul gibberish approximating English phonemes.
                // Leaving it nil lets the transcript speak for itself through
                // script detection, which is the signal the cross-language rule
                // needs. Pinning belongs to dual mode, where a channel genuinely
                // IS one language by construction.
                ChannelSpec(
                    selection: source, label: "challenger", engine: .rtzr,
                    pinnedLanguage: nil, sampleRate: AudioChunker.rtzrSampleRate,
                    role: .challenger),
            ]

        case .bidirectionalDual:
            // The guests are on the call's audio speaking Korean; the operator is
            // on the microphone speaking English. Direction is known per channel,
            // so nothing is detected and no arbitration is needed.
            //
            // A microphone `audioSource` is contradictory here — the mic is
            // already claimed by the operator's channel — so fall back to
            // system-wide capture for the guest side.
            let guestSource: AudioSourceSelection =
                source == .microphone ? .systemAudio : source
            let english = Self.englishEngine()
            return [
                ChannelSpec(
                    selection: guestSource, label: "guests", engine: .rtzr,
                    pinnedLanguage: .ko, sampleRate: AudioChunker.rtzrSampleRate,
                    role: .direct),
                ChannelSpec(
                    selection: .microphone, label: "operator", engine: english,
                    pinnedLanguage: .en, sampleRate: Self.sampleRate(for: english),
                    role: .direct),
            ]
        }
    }

    /// Each engine's required input rate.
    static func sampleRate(for engine: STTEngine) -> Double {
        switch engine {
        case .rtzr: return AudioChunker.rtzrSampleRate
        case .openai: return AudioChunker.openAISampleRate
        }
    }

    private func route(_ message: STTMessage, role: ChannelRole) {
        switch role {
        case .direct:
            store.apply(message)
            // Nothing will arbitrate this channel — it is the only engine on this
            // audio, or its direction is known by construction. Mark the source as
            // the transcript of record so `.arbitrated` means "nothing more will
            // change this text" in EVERY capture mode. Without this, `sourceState`
            // stayed `.draft` forever in koreanOnly and dual mode, and the
            // Presentation window's "translation is final" rule — gated on
            // `.arbitrated` — never drew in the app's default mode.
            if message.isFinal { store.confirmSource(id: message.seq) }
        case .segmenter:
            coordinator?.ingestSegmenter(message)
        case .challenger:
            // Partials from the challenger are dropped on purpose: the hypothesis
            // line belongs to the segmenter, and alternating between two engines'
            // guesses would make it flip-flop mid-word.
            guard message.isFinal else { return }
            coordinator?.ingestChallenger(message)
        }
    }

    private static func missingCredentialMessage(for mode: CaptureMode) -> String {
        if !Credentials.hasRTZR { return RTZRError.missingCredentials.localizedDescription }
        if mode.isBidirectional, !Credentials.hasOpenAI {
            return """
                OpenAI API key not configured — bidirectional capture needs it to \
                transcribe English. Add it in Settings → API Keys, or switch \
                Transcription → Capture mode back to Korean only.
                """
        }
        // Name the provider the user actually selected, not whichever one the
        // pipeline happens to check first.
        return switch AppSettings.shared.translationProvider {
        case .anthropic: TranslationServiceError.missingAPIKey.localizedDescription
        case .openRouter: TranslationServiceError.missingOpenRouterKey.localizedDescription
        }
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
            // A CHALLENGER is an optional second opinion — it never reaches the store
            // and owns no boundaries. Tearing the session down when it dies took the
            // healthy segmenter with it and ended the meeting over the loss of an
            // arbitration. Degrade to single-engine instead and keep captioning.
            if channels.indices.contains(index), channels[index].spec.role == .challenger {
                DiagnosticLog.shared.warn("session", "challenger_lost_continuing", [
                    "channel": label,
                    "error": message,
                ])
                let dying = channels[index]
                await dying.transcriber.detach()
                dying.capture.stop()
                await dying.transcriber.stop()
                channels.remove(at: index)
                channelStates.remove(at: index)
                connectionState = Self.mergedState(channelStates)
                return
            }
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
        // `isListening` is false during start()'s async window and during a
        // teardown, so the old `guard isListening` silently dropped the change and
        // left the menu and status line naming audio the session was not capturing.
        // Route through the coalescing restart, which waits its turn instead.
        guard isListening || isStarting || isStopping || restartInFlight else { return }
        restartIfListening(force: true)
    }

    /// Restart capture so a capture-mode or provider change takes effect. No-op
    /// when idle — the next start picks the new settings up anyway.
    ///
    /// Serialized through `restartInFlight`/`restartPending`. Two rapid changes
    /// (the settings poll fires every 0.25s, and one click on the capture-mode
    /// picker triggers a restart) used to race: the second request's `stop()` saw
    /// `isListening == false` and returned, then its `start()` hit the `isStarting`
    /// guard and returned too — so the session kept running on the OLD settings
    /// with the UI showing the new ones. Coalescing to one trailing restart means
    /// the last request always wins.
    /// `force` lets a caller queue a restart during start()'s async window or a
    /// teardown, when `isListening` is momentarily false but a session is very much
    /// on its way in or out. Without it a settings or source change made in that
    /// window was lost permanently.
    /// Returns whether the restart was accepted. Callers that record "handled"
    /// state — `AppDelegate.lastCaptureMode` — must only advance it on true, or a
    /// change made while no session existed is remembered as applied and never is.
    @discardableResult
    func restartIfListening(force: Bool = false) -> Bool {
        guard force || isListening || restartInFlight else { return false }
        // Nothing to restart and nothing on its way: the next start() reads the new
        // settings anyway, so report handled.
        guard isListening || isStarting || isStopping || restartInFlight else { return true }
        if restartInFlight {
            restartPending = true
            return true
        }
        restartInFlight = true
        Task { @MainActor in
            repeat {
                restartPending = false
                await stop()
                await start()
            } while restartPending
            restartInFlight = false
        }
        return true
    }

    // MARK: - Level metering

    private func attachLevelMeter(to capture: AudioCapturing) {
        let sink: (Float) -> Void = { [weak self] level in
            Task { @MainActor [weak self] in self?.ingestLevel(level) }
        }
        if let mic = capture as? MicrophoneCaptureService { mic.onLevel = sink }
        if let system = capture as? SystemAudioCaptureService { system.onLevel = sink }
    }

    /// Attack fast, release slow: a meter that decays as quickly as speech does
    /// looks like it is flickering rather than following a voice.
    private func ingestLevel(_ raw: Float) {
        // Speech RMS sits well below 1.0; scale so normal talking fills the meter.
        let scaled = min(1, raw * 4)
        audioLevel = scaled > audioLevel
            ? audioLevel + (scaled - audioLevel) * 0.6
            : audioLevel + (scaled - audioLevel) * 0.18
    }

    // MARK: - Liveness

    /// Pass-through wrapper that counts audio chunks, so the heartbeat can
    /// tell "audio flowing but STT silent" (server problem) apart from
    /// "no audio at all" (capture problem) when a session goes quiet.
    /// The counter is shared across channels (start() resets it once).
    ///
    /// The buffering policy must MATCH the source stream's. Both capture services
    /// hand out `.bufferingNewest(50)` — a deliberate ~5s bound with the comment
    /// "if the websocket stalls, drop the oldest audio instead of growing memory
    /// and replaying stale speech after recovery". `AsyncStream`'s default policy
    /// is `.unbounded`, so wrapping without specifying one silently discarded that
    /// backpressure: the transcriber's pump applies real backpressure at
    /// `socket.send`, so a congested uplink would accumulate every chunk here
    /// instead of dropping the oldest, and on recovery replay a minute of stale
    /// audio — leaving captions permanently behind the speaker for the rest of the
    /// meeting.
    private func counted(_ audio: AsyncStream<Data>) -> AsyncStream<Data> {
        let counter = audioChunkCounter
        return AsyncStream(Data.self, bufferingPolicy: .bufferingNewest(50)) { continuation in
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
            "capture_mode": settings.captureMode.rawValue,
            "utterances": store.utterances.count,
            "translated": store.utterances.filter { $0.state == .translated }.count,
            "failed": store.utterances.filter { $0.state == .failed }.count,
            "korean_spoken": store.utterances.filter { $0.sourceLanguage == .ko }.count,
            "english_spoken": store.utterances.filter { $0.sourceLanguage == .en }.count,
            "queue_depth": translationQueue.depth,
            "speculations_live": speculations.count,
            "audio_chunks_30s": chunks,
            "stt_silence_s": sttSilence.map { Int($0) } ?? -1,
        ])
        // Audio is flowing but STT has said nothing for 2 minutes: the stream is
        // wedged in a way the reconnect logic didn't catch.
        if let silence = sttSilence, silence > 120, chunks > 0, isListening {
            DiagnosticLog.shared.error("session", "stt_stalled", [
                "stt_silence_s": Int(silence),
                "audio_chunks_30s": chunks,
            ])
        }
    }

    // MARK: - Speculative translation

    /// The hypothesis grew. Decide whether it grew enough to be worth another
    /// translation pass, and fire one if so.
    private func considerSpeculation(for partial: Utterance) {
        guard settings.speculativeTranslation, isListening else { return }
        // A hypothesis can be superseded without ever finalizing (the speaker
        // trails off, or the engine discards the segment). handleFinalized is the
        // only other place these entries are cleaned up, so without this the
        // dictionary and its cancelled-but-unreleased tasks grew for the whole
        // meeting. Same id band = same channel, so only that channel's stale
        // hypotheses are dropped.
        let band = partial.id / Self.channelIDStride
        for (id, state) in speculations
        where id != partial.id && id / Self.channelIDStride == band {
            state.inFlight?.cancel()
            speculations[id] = nil
        }
        let text = partial.sourceText
        guard text.count >= Self.speculativeMinLength else { return }

        var state = speculations[partial.id] ?? SpeculationState()
        let now = Date()
        guard now.timeIntervalSince(state.lastFiredAt) >= Self.speculativeMinInterval else { return }
        let threshold = partial.sourceLanguage == .ko
            ? Self.speculativeKoreanGrowth
            : Self.speculativeEnglishGrowth
        guard text.count - state.lastFiredLength >= threshold else { return }

        // The previous pass was guessing at a shorter sentence; its answer is
        // already obsolete, so stop paying for it.
        state.inFlight?.cancel()
        state.revision += 1
        state.lastFiredAt = now
        state.lastFiredLength = text.count

        let revision = state.revision
        let seq = partial.id
        let source = partial.sourceLanguage
        let context = store.contextPairs(before: seq, from: source, limit: 6)
        let translator = self.translator
        let store = self.store

        state.inFlight = Task { @MainActor in
            var collected = ""
            do {
                for try await token in translator.streamTranslation(
                    of: text, from: source, to: source.other,
                    context: context, forbidSkip: false)
                {
                    if Task.isCancelled { return }
                    collected += token
                    store.streamPartialTranslation(seq: seq, text: collected)
                }
            } catch {
                // A failed speculative pass is not an error worth surfacing: the
                // final pass still runs, and the hypothesis is about to change
                // anyway. Log at debug volume and move on.
                DiagnosticLog.shared.warn("translate", "speculative_failed", [
                    "seq": seq,
                    "revision": revision,
                    "error": error.localizedDescription,
                ])
                return
            }
            guard !Task.isCancelled else { return }
            // A ∅ mid-sentence means "nothing translatable yet", not "skip this
            // utterance" — never let it reach the consensus merge.
            guard !TranslationFilter.isFiller(collected) else { return }
            store.applyPartialSpeculative(seq: seq, revision: revision, text: collected)
        }

        speculations[partial.id] = state
        DiagnosticLog.shared.info("translate", "speculative_fired", [
            "seq": seq,
            "revision": revision,
            "source_chars": text.count,
            "direction": "\(source.rawValue)->\(source.other.rawValue)",
        ])
    }

    // MARK: - Finalization + translation

    private func handleFinalized(_ utterance: Utterance) {
        // The hypothesis is gone; its speculation bookkeeping goes with it.
        speculations[utterance.id]?.inFlight?.cancel()
        speculations[utterance.id] = nil
        recorder.recordFinal(utterance)
        enqueueTranslation(for: utterance)
    }

    /// The judge overruled the cheap pick after the fact. Replace the source and
    /// re-translate once — the old translation was of text nobody said.
    private func handleArbitrationCorrection(id: Int, text: String, language: Language) {
        guard let existing = store.utterances.first(where: { $0.id == id }) else { return }
        guard existing.sourceText != text else {
            store.confirmSource(id: id)
            return
        }
        DiagnosticLog.shared.info("stt", "source_corrected", [
            "id": id,
            "was": String(existing.sourceText.prefix(60)),
            "now": String(text.prefix(60)),
        ])
        store.applyArbitration(id: id, text: text, language: language)
        store.restartTranslation(id: id)
        if let corrected = store.utterances.first(where: { $0.id == id }) {
            recorder.recordFinal(corrected)
            enqueueTranslation(for: corrected)
        }
    }

    /// Newest translation generation per utterance id. A judge correction
    /// re-enqueues an utterance, and `TranslationQueue` runs two jobs at a time,
    /// so the superseded job is still streaming when its replacement starts.
    ///
    /// Without this guard both wrote through `store.streamTranslation(id:)` into
    /// the same row, interleaving token by token — and after a direction flip the
    /// loser's English was written into the Korean column. Whichever finished last
    /// called `settleTranslation`, so roughly half the time the row settled
    /// permanently on the translation of a transcript that had already been
    /// discarded, was marked `.translated`, and was written to disk.
    private var translationGeneration: [Int: Int] = [:]

    /// Incremented on every `start()`. A job from a stopped session must not
    /// write into the new one: `startSession()` wipes the store and
    /// `recorder.begin()` opens a fresh events.jsonl, and ids repeat across
    /// sessions (each channel's seq restarts inside the same id band), so a
    /// straggler would append a `translation_done` for an id the new session's log
    /// has no `korean_final` for — or overwrite a live row with the previous
    /// meeting's text. Reachable with one click on the capture-mode picker, which
    /// restarts capture.
    private var sessionEpoch = 0

    /// True when this job is still the one that owns the row.
    private func isCurrentTranslation(id: Int, generation: Int, epoch: Int) -> Bool {
        epoch == sessionEpoch && translationGeneration[id] == generation
    }

    private func enqueueTranslation(for utterance: Utterance) {
        let translator = self.translator
        let store = self.store
        let recorder = self.recorder
        let queue = self.translationQueue
        let queuedAt = Date()
        let source = utterance.sourceLanguage
        let generation = (translationGeneration[utterance.id] ?? 0) + 1
        translationGeneration[utterance.id] = generation
        let epoch = sessionEpoch
        DiagnosticLog.shared.info("translate", "queued", [
            "id": utterance.id,
            "queue_depth": queue.depth,
            "generation": generation,
            "source_chars": utterance.sourceText.count,
            "direction": "\(source.rawValue)->\(source.other.rawValue)",
        ])
        queue.enqueue { @MainActor [weak self] in
            // Superseded or session-stale before it even started.
            guard let self, self.isCurrentTranslation(
                id: utterance.id, generation: generation, epoch: epoch) else {
                DiagnosticLog.shared.info("translate", "superseded_before_start", [
                    "id": utterance.id, "generation": generation,
                ])
                return
            }
            let startedAt = Date()
            let context = store.contextPairs(before: utterance.id, from: source)
            var firstTokenAt: Date?
            // Declared out here so the catch block can log/record the partial.
            var collected = ""

            // One streaming pass into the row.
            //
            // `discardPrevious` is false on the first pass and true on the forced
            // retry. The distinction is load-bearing: the first pass must KEEP the
            // words committed while the sentence was still a hypothesis, or the
            // translation visibly resets to grey the moment the speaker stops. The
            // retry is re-translating from scratch after a wrong ∅, so nothing
            // previously committed can be trusted and the frontier goes with it.
            @MainActor func stream(forbidSkip: Bool, discardPrevious: Bool) async throws {
                if discardPrevious {
                    store.restartTranslation(id: utterance.id)
                } else {
                    store.beginTranslationPass(id: utterance.id)
                }
                collected = ""
                for try await token in translator.streamTranslation(
                    of: utterance.sourceText, from: source, to: source.other,
                    context: context, forbidSkip: forbidSkip)
                {
                    // Re-checked every token, not just at entry: a judge
                    // correction can supersede this job mid-stream, and the
                    // replacement is already writing to the same row.
                    guard self.isCurrentTranslation(
                        id: utterance.id, generation: generation, epoch: epoch) else {
                        throw CancellationError()
                    }
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    collected += token
                    store.streamTranslation(id: utterance.id, text: collected)
                }
            }

            do {
                try await stream(forbidSkip: false, discardPrevious: false)
                var forced = false

                // The model emitted the skip sentinel, but the source clearly
                // carries content. That's the over-skip bug: re-translate once
                // with skipping forbidden rather than silently dropping a real
                // line. (Genuine short filler falls through and is dropped.)
                if TranslationFilter.isFiller(collected),
                   TranslationFilter.sourceHasSubstance(utterance.sourceText) {
                    forced = true
                    // Guarded like every other write in this job: restartTranslation
                    // wipes the row outright, so a superseded job reaching here would
                    // erase whatever its replacement had already streamed or settled.
                    guard self.isCurrentTranslation(
                        id: utterance.id, generation: generation, epoch: epoch) else {
                        DiagnosticLog.shared.info("translate", "superseded_before_retry", [
                            "id": utterance.id, "generation": generation,
                        ])
                        return
                    }
                    DiagnosticLog.shared.warn("translate", "filler_override", [
                        "id": utterance.id,
                        "source_chars": utterance.sourceText.count,
                    ])
                    try await stream(forbidSkip: true, discardPrevious: true)
                }

                guard self.isCurrentTranslation(
                    id: utterance.id, generation: generation, epoch: epoch) else {
                    DiagnosticLog.shared.info("translate", "superseded_before_settle", [
                        "id": utterance.id, "generation": generation,
                    ])
                    return
                }

                if TranslationFilter.isFiller(collected) {
                    store.clearTranslation(id: utterance.id)
                    DiagnosticLog.shared.info("translate", "skipped_filler", [
                        "id": utterance.id,
                        "raw": String(collected.prefix(80)),
                        "forced": forced,
                    ])
                } else {
                    // settle() runs the consensus merge one last time and commits
                    // everything, so words that were already committed while the
                    // sentence was a hypothesis stay put.
                    store.settleTranslation(id: utterance.id, text: collected)
                    DiagnosticLog.shared.info("translate", "completed", [
                        "id": utterance.id,
                        "wait_ms": Int(startedAt.timeIntervalSince(queuedAt) * 1000),
                        "ttft_ms": firstTokenAt.map { Int($0.timeIntervalSince(startedAt) * 1000) } ?? -1,
                        "total_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                        "target_chars": collected.count,
                        "forced": forced,
                    ])
                }
                // Only settled text is persisted — speculative revisions never
                // reach disk or the cloud.
                recorder.recordTranslation(
                    id: utterance.id,
                    text: TranslationFilter.isFiller(collected) ? "" : collected,
                    language: source.other,
                    failed: false)
            } catch is CancellationError {
                // Superseded mid-stream. The replacement job owns the row; saying
                // anything here would overwrite it or mark it failed.
                DiagnosticLog.shared.info("translate", "superseded_mid_stream", [
                    "id": utterance.id, "generation": generation,
                ])
                return
            } catch {
                guard self.isCurrentTranslation(
                    id: utterance.id, generation: generation, epoch: epoch) else { return }
                store.failTranslation(id: utterance.id)
                DiagnosticLog.shared.error("translate", "failed", [
                    "id": utterance.id,
                    "error": error.localizedDescription,
                    "wait_ms": Int(startedAt.timeIntervalSince(queuedAt) * 1000),
                    "partial_chars": collected.count,
                ])
                recorder.recordTranslation(
                    id: utterance.id, text: collected, language: source.other, failed: true)
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

    /// Wait for in-flight jobs to finish, bounded by `timeout`.
    ///
    /// Load-bearing on stop(): `SessionRecorder.end` writes the final
    /// transcript.md, appends session_end, uploads to the cloud and then closes
    /// its file handle. Any translation job still streaming when that happens has
    /// its `recordTranslation` and `scheduleSnapshot` silently dropped by the
    /// recorder's own `guard`s — so the last sentence of the meeting appeared on
    /// screen but was permanently missing from the saved transcript, events.jsonl
    /// and the cloud copy. Stopping right after the last sentence is the normal
    /// way a meeting ends, so this was not an edge case.
    func drain(timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while depth > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
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
