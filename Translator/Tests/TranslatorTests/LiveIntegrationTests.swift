import XCTest
import AVFoundation
@testable import Translator

/// Live integration tests. **Opt-in**: they hit real endpoints with the user's real
/// keys and cost money, so they only run when `MALDARI_LIVE=1` is set. `swift test`
/// skips them silently otherwise, which is why the normal suite stays hermetic.
///
///     MALDARI_LIVE=1 MALDARI_LIVE_AUDIO=/path/to/16k.wav \
///       DEVELOPER_DIR=/Applications/Xcode.app swift test --filter LiveIntegration
///
/// These exist because everything else in this suite mocks the network boundary, and
/// the failure that started this work — a Korean-only recognizer transcribing English
/// as Hangul, then the translator politely asking the room to repeat itself — was
/// invisible to every mocked test.
final class LiveIntegrationTests: XCTestCase {

    private var live: Bool { ProcessInfo.processInfo.environment["MALDARI_LIVE"] == "1" }

    private func audioURL(_ key: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[key] else {
            throw XCTSkip("\(key) not set")
        }
        return URL(fileURLWithPath: path)
    }

    /// Read a mono Int16 WAV into the 100 ms `Data` chunks the capture layer emits.
    private func chunks(from url: URL, expectedRate: Double) throws -> [Data] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        XCTAssertEqual(format.sampleRate, expectedRate, accuracy: 1,
                       "fixture must already be at the engine's rate")
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw XCTSkip("could not allocate read buffer")
        }
        try file.read(into: buffer)

        // Convert to interleaved Int16, which is what the wire format is.
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: expectedRate, channels: 1, interleaved: true)!
        var pcm = Data()
        if format.commonFormat == .pcmFormatInt16, let raw = buffer.int16ChannelData {
            pcm.append(Data(bytes: raw[0], count: Int(buffer.frameLength) * 2))
        } else {
            let converter = AVAudioConverter(from: format, to: target)!
            let out = AVAudioPCMBuffer(pcmFormat: target,
                                       frameCapacity: AVAudioFrameCount(file.length) + 1024)!
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            XCTAssertNil(err)
            if let raw = out.int16ChannelData {
                pcm.append(Data(bytes: raw[0], count: Int(out.frameLength) * 2))
            }
        }

        let bytesPerChunk = Int(expectedRate / 10) * 2
        var result: [Data] = []
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + bytesPerChunk, pcm.count)
            result.append(pcm.subdata(in: offset..<end))
            offset = end
        }
        return result
    }

    /// Feed chunks at wall-clock pace, because both engines' VAD is timing-sensitive:
    /// dumping five seconds of audio instantly produces one giant turn or none at all.
    /// How long `stream` takes to emit everything, so a test waits for the audio
    /// to actually arrive before stopping. Getting this wrong made RTZR and OpenAI
    /// both look broken: `start()` returns as soon as it spawns its pump, so a fixed
    /// 4s wait overlapped 6.7s of streaming and `stop()` fired mid-utterance, before
    /// either engine had seen a complete turn or an EOS.
    private func streamDuration(_ chunks: [Data]) -> TimeInterval {
        Double(chunks.count + 12) * 0.1
    }

    /// Records the moment the audio stream ended, so a test can tell a final that
    /// the engine produced *while listening* from one that only appeared because the
    /// stream closed.
    private final class StreamClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _finishedAt: Date?
        var finishedAt: Date? {
            lock.lock(); defer { lock.unlock() }
            return _finishedAt
        }
        func finish() { lock.lock(); _finishedAt = Date(); lock.unlock() }
    }

    /// `silenceChunks` is deliberately long. `finishStream()` sends
    /// `input_audio_buffer.commit` when the audio stream ENDS, which forces a final
    /// out of the server — so a test whose audio simply stops will see a final
    /// regardless of whether turn detection works at all. That is exactly how a
    /// broken model shipped: the app's audio never ends, so it never got that
    /// courtesy commit and never finalized anything. Holding the stream open for
    /// seconds after the speech means a final can only arrive from real VAD.
    private func stream(
        _ chunks: [Data], silenceChunks: Int = 12, clock: StreamClock? = nil,
        realTime: Bool = true
    ) -> AsyncStream<Data> {
        AsyncStream { continuation in
            Task {
                for chunk in chunks {
                    continuation.yield(chunk)
                    if realTime { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                // Trailing silence so end-point detection closes the utterance.
                let silence = Data(repeating: 0, count: chunks.first?.count ?? 3200)
                for _ in 0..<silenceChunks {
                    continuation.yield(silence)
                    if realTime { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                clock?.finish()
                continuation.finish()
            }
        }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [STTMessage] = []
        private var _states: [STTConnectionState] = []
        var finals: [STTMessage] {
            lock.lock(); defer { lock.unlock() }
            return _messages.filter(\.isFinal)
        }
        var partials: [STTMessage] {
            lock.lock(); defer { lock.unlock() }
            return _messages.filter { !$0.isFinal }
        }
        var states: [STTConnectionState] {
            lock.lock(); defer { lock.unlock() }
            return _states
        }
        private var _firstFinalAt: Date?
        /// When the first final arrived. The whole point of the mid-stream
        /// assertion below.
        var firstFinalAt: Date? {
            lock.lock(); defer { lock.unlock() }
            return _firstFinalAt
        }
        func message(_ m: STTMessage) {
            lock.lock()
            _messages.append(m)
            if m.isFinal, _firstFinalAt == nil { _firstFinalAt = Date() }
            lock.unlock()
        }
        func state(_ s: STTConnectionState) { lock.lock(); _states.append(s); lock.unlock() }
    }

    // MARK: - OpenAI Realtime

    func test_openAIRealtime_transcribesEnglish() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(Credentials.hasOpenAI, "no OpenAI key")
        let url = try audioURL("MALDARI_LIVE_AUDIO_24K")

        let service = OpenAIRealtimeSTTService(pinnedLanguage: .en, logChannel: "test")
        let sink = Sink()
        service.onMessage = { sink.message($0) }
        service.onStateChange = { sink.state($0) }

        let pieces = try chunks(from: url, expectedRate: 24_000)
        // 40 chunks (~4s) of trailing silence: far longer than the 500ms the VAD
        // needs, so a working engine finalizes long before the stream closes.
        let clock = StreamClock()
        let silenceChunks = 40
        await service.start(audio: stream(pieces, silenceChunks: silenceChunks, clock: clock))
        try await Task.sleep(
            nanoseconds: UInt64((Double(pieces.count + silenceChunks) * 0.1 + 6) * 1_000_000_000))
        await service.stop()

        let text = sink.finals.compactMap(\.bestText).joined(separator: " ")
        print("[openai] states: \(sink.states.map(\.label))")
        print("[openai] partials: \(sink.partials.count) finals: \(sink.finals.count) | \(text)")
        XCTAssertFalse(text.isEmpty, "expected a transcript, states: \(sink.states.map(\.label))")
        XCTAssertEqual(ScriptDetector.language(of: text), .en)

        // THE assertion this file exists for. Server-side turn detection must close
        // the utterance on silence, while audio is still arriving. Without it the app
        // streamed deltas forever: one hypothesis grew past 1,150 characters,
        // `utterances` stayed at 0, and 67 speculative translations fired on a line
        // that never landed. A stream that ends triggers a courtesy commit and hides
        // all of that, which is why the earlier version of this test passed against a
        // model that could not segment at all.
        let firstFinal = try XCTUnwrap(
            sink.firstFinalAt,
            "no final ever arrived — turn detection is not segmenting")
        let streamEnded = try XCTUnwrap(clock.finishedAt, "stream never finished")
        XCTAssertLessThan(
            firstFinal, streamEnded,
            "the final only appeared because the audio stopped. A meeting's audio "
            + "never stops, so this engine would never finalize anything.")
    }

    // MARK: - RTZR (the Korean specialist, on Korean audio)

    func test_rtzr_transcribesKorean() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(Credentials.hasRTZR, "no RTZR key")
        let url = try audioURL("MALDARI_LIVE_AUDIO_KO_16K")

        let service = RTZRStreamingService(keywords: { [] }, logChannel: "test")
        let sink = Sink()
        service.onMessage = { sink.message($0) }
        service.onStateChange = { sink.state($0) }

        let pieces = try chunks(from: url, expectedRate: 16_000)
        await service.start(audio: stream(pieces))
        // Wait out the whole stream plus settling time for the final to come back.
        try await Task.sleep(
            nanoseconds: UInt64((streamDuration(pieces) + 6) * 1_000_000_000))
        await service.stop()

        let text = sink.finals.compactMap(\.bestText).joined(separator: " ")
        print("[rtzr] states: \(sink.states.map(\.label)) | \(text)")
        XCTAssertFalse(text.isEmpty, "expected Korean, states: \(sink.states.map(\.label))")
        XCTAssertEqual(ScriptDetector.language(of: text), .ko)
    }

    // MARK: - Translation, live

    /// The exact strings that were printed to the room as refusals.
    func test_liveTranslation_skipsMisheardEnglishInsteadOfRefusing() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(Credentials.hasAnthropic, "no Anthropic key")
        let service = ClaudeTranslationService()

        for gibberish in ["하다 마이님 쬐하네", "오리미 유키한 스마글셔 스"] {
            var out = ""
            for try await token in service.streamTranslation(
                of: gibberish, from: .ko, to: .en, context: [], forbidSkip: false) {
                out += token
            }
            print("[translate] \(gibberish) -> \(out)")
            XCTAssertTrue(TranslationFilter.isFiller(out),
                          "mis-heard English must be skipped, got: \(out)")
            XCTAssertFalse(out.lowercased().contains("clarify"),
                           "a refusal must never be produced: \(out)")
        }
    }

    func test_liveTranslation_bothDirections() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(Credentials.hasAnthropic, "no Anthropic key")
        let service = ClaudeTranslationService()

        var koToEn = ""
        for try await t in service.streamTranslation(
            of: "검토해보겠습니다", from: .ko, to: .en, context: [], forbidSkip: false) { koToEn += t }
        print("[translate ko->en] \(koToEn)")
        XCTAssertFalse(TranslationFilter.isFiller(koToEn))
        XCTAssertEqual(ScriptDetector.language(of: koToEn), .en)
        // The project's canonical fidelity case: a hedge must not harden.
        XCTAssertTrue(koToEn.lowercased().contains("look into"),
                      "commitment level must be preserved: \(koToEn)")

        var enToKo = ""
        for try await t in service.streamTranslation(
            of: "Could you send that breakdown by Friday?",
            from: .en, to: .ko, context: [], forbidSkip: false) { enToKo += t }
        print("[translate en->ko] \(enToKo)")
        XCTAssertFalse(TranslationFilter.isFiller(enToKo))
        XCTAssertEqual(ScriptDetector.language(of: enToKo), .ko,
                       "an EN→KO request must return Korean: \(enToKo)")
    }

    // MARK: - The multi-agent debate

    /// The case the debate exists for: RTZR heard English as Hangul, the other engine
    /// heard it correctly. The debate must pick the English one AND correct the
    /// language, since only a corrected language routes the translation the right way.
    func test_liveDebate_picksEnglishAndFlipsTheLanguage() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(Credentials.hasAnthropic, "no Anthropic key")

        let debate = TranscriptDebate()
        let candidates = [
            TranscriptArbiter.Candidate(
                engine: .rtzr, text: "쿠쥬 센드 댓 브레이크다운 바이 프라이데이",
                confidence: 0.86, reportedLanguage: nil),
            TranscriptArbiter.Candidate(
                engine: .openai, text: "Could you send that breakdown by Friday?",
                confidence: 0.91, reportedLanguage: .en),
        ]
        let assumed = Language.ko
        let verdict = await debate.judge(
            candidates: candidates, language: assumed,
            context: ["단가를 맞추기 어렵습니다", "We can look at eight thousand units."])

        print("[debate] verdict: \(String(describing: verdict))")
        let v = try XCTUnwrap(verdict, "the debate must not abstain on a clear case")
        XCTAssertEqual(v.engine, .openai, "the correct English transcript must win")
        XCTAssertGreaterThanOrEqual(v.confidence, TranscriptDebate.minimumConfidence)

        // Assert the EFFECTIVE outcome, resolved the way ArbitrationCoordinator
        // resolves it. Demanding `v.language == .en` would require the verdict to
        // restate what the winning candidate already carries; what actually matters
        // is that the utterance ends up routed as English rather than Korean.
        let winner = try XCTUnwrap(candidates.first { $0.engine == v.engine })
        let effectiveLanguage = v.language ?? winner.language ?? assumed
        let effectiveText = v.text ?? winner.text
        XCTAssertEqual(effectiveLanguage, .en,
                       "the utterance must end up English, not the assumed Korean")
        XCTAssertEqual(ScriptDetector.language(of: effectiveText), .en,
                       "the published text must be the English one: \(effectiveText)")
    }

    /// The other half: when both engines agree, the debate must not invent a change.
    func test_liveDebate_abstainsWhenCandidatesAgree() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(Credentials.hasAnthropic, "no Anthropic key")

        let debate = TranscriptDebate()
        let same = "금형 비용은 별도로 청구됩니다"
        let verdict = await debate.judge(
            candidates: [
                TranscriptArbiter.Candidate(engine: .rtzr, text: same,
                                            confidence: 0.95, reportedLanguage: .ko),
                TranscriptArbiter.Candidate(engine: .openai, text: same,
                                            confidence: 0.6, reportedLanguage: .ko),
            ],
            language: .ko, context: [])
        print("[debate agree] verdict: \(String(describing: verdict))")
        if let verdict {
            XCTAssertEqual(verdict.text ?? same, same,
                           "identical candidates must not be rewritten")
            XCTAssertEqual(verdict.language ?? .ko, .ko)
        }
    }

    // MARK: - OpenRouter

    func test_liveOpenRouter_translates() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(Credentials.hasOpenRouter, "no OpenRouter key")

        let models = try await OpenRouterTranslationService.fetchModels()
        print("[openrouter] \(models.count) models")
        XCTAssertGreaterThan(models.count, 10)

        let service = OpenRouterTranslationService(model: { "openai/gpt-4o-mini" })
        var out = ""
        for try await t in service.streamTranslation(
            of: "안녕하세요", from: .ko, to: .en, context: [], forbidSkip: false) { out += t }
        print("[openrouter] 안녕하세요 -> \(out)")
        XCTAssertFalse(out.isEmpty)
        XCTAssertEqual(ScriptDetector.language(of: out), .en)
    }

    // MARK: - End to end: audio in, translated text on screen

    /// The gap that let "nothing translates" ship.
    ///
    /// Every other test in this file checks one leg in isolation — the STT engines
    /// transcribe, the translator translates, the debate arbitrates — and every one
    /// of them passed while the app showed the user an empty column. The failure was
    /// entirely in the seam: the segmenter never closed an utterance, so a working
    /// transcriber and a working translator were never introduced to each other.
    ///
    /// These two tests drive the real `PipelineController` from audio all the way to
    /// `store.utterances`, which is exactly what the window renders. Nothing between
    /// the WAV and the assertion is mocked except the audio device.

    /// Replays a fixture instead of opening a device.
    ///
    /// Dispatches on the requested sample rate because `bidirectionalSingle` runs TWO
    /// captures of the same source — 24 kHz for the OpenAI segmenter, 16 kHz for the
    /// RTZR challenger — since one capture cannot emit two rates.
    ///
    /// **It never ends the stream on its own, and that is the whole design.** A
    /// microphone does not stop because the speaker paused; it keeps handing over
    /// silence until the session is torn down. An earlier version of this fixture
    /// played the speech and then finished the stream, which made
    /// `OpenAIRealtimeSTTService.finishStream()` send `input_audio_buffer.commit` as
    /// EOS — forcing the server to emit a final regardless of whether turn detection
    /// worked. Verified by mutation: with turn detection disabled, that version of
    /// this test still produced a flawless Korean-to-English line and passed, which
    /// is precisely the bug the user reported. Streaming silence indefinitely means a
    /// final can only ever come from real segmentation.
    private final class FixtureCapture: AudioCapturing {
        private let chunks: [Data]
        private var pump: Task<Void, Never>?

        init(chunks: [Data]) {
            self.chunks = chunks
        }

        func start() async throws -> AsyncStream<Data> {
            let chunks = self.chunks
            return AsyncStream { continuation in
                pump = Task {
                    for chunk in chunks {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    // Open mic, forever. Only `stop()` ends this.
                    let silence = Data(repeating: 0, count: chunks.first?.count ?? 3200)
                    while !Task.isCancelled {
                        continuation.yield(silence)
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    continuation.finish()
                }
            }
        }

        func stop() {
            pump?.cancel()
            pump = nil
        }
    }

    /// Runs one real bidirectional session against canned audio and returns what the
    /// window would show.
    @MainActor
    private func runSession(at16k: [Data], at24k: [Data]) async throws -> [Utterance] {
        let settings = AppSettings.shared
        let previousMode = settings.captureModeRaw
        settings.captureModeRaw = CaptureMode.bidirectionalSingle.rawValue
        defer { settings.captureModeRaw = previousMode }

        let pipeline = PipelineController()
        pipeline.makeCapture = { _, sampleRate in
            FixtureCapture(chunks: sampleRate >= 20_000 ? at24k : at16k)
        }

        await pipeline.start()
        try XCTSkipUnless(pipeline.isListening, "session refused to start")

        // Speech, then long enough for VAD to close the utterance and the
        // translation to stream — all while the mic is still open.
        let seconds = Double(max(at16k.count, at24k.count)) * 0.1 + 16
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await pipeline.stop()
        return pipeline.store.utterances
    }

    /// Reports what landed, so a failure is diagnosable without a rerun.
    private func describe(_ lines: [Utterance]) -> String {
        lines.map { "[\($0.sourceLanguage.rawValue)] \($0.sourceText) => \($0.targetText)" }
            .joined(separator: "\n")
    }

    @MainActor
    func test_endToEnd_koreanSpeechLandsAsEnglish() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(Credentials.hasOpenAI, "no OpenAI key")
        try XCTSkipUnless(Credentials.hasRTZR, "no RTZR key")
        try XCTSkipUnless(Credentials.hasAnthropic, "no Anthropic key")

        let lines = try await runSession(
            at16k: try chunks(from: try audioURL("MALDARI_LIVE_AUDIO_KO_16K"),
                              expectedRate: 16_000),
            at24k: try chunks(from: try audioURL("MALDARI_LIVE_AUDIO_KO_24K"),
                              expectedRate: 24_000))
        print("[e2e ko]\n\(describe(lines))")

        XCTAssertFalse(lines.isEmpty, "no utterance ever finalized — nothing would render")
        let korean = try XCTUnwrap(
            lines.first { $0.sourceLanguage == .ko && !$0.targetText.isEmpty },
            "Korean speech produced no English. This is the reported bug:\n"
            + describe(lines))
        XCTAssertEqual(ScriptDetector.language(of: korean.targetText), .en,
                       "Korean must come out as English: \(korean.targetText)")
        XCTAssertFalse(TranslationFilter.isFiller(korean.targetText))
    }

    @MainActor
    func test_endToEnd_englishSpeechLandsAsKorean() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(Credentials.hasOpenAI, "no OpenAI key")
        try XCTSkipUnless(Credentials.hasRTZR, "no RTZR key")
        try XCTSkipUnless(Credentials.hasAnthropic, "no Anthropic key")

        let lines = try await runSession(
            at16k: try chunks(from: try audioURL("MALDARI_LIVE_AUDIO_16K"),
                              expectedRate: 16_000),
            at24k: try chunks(from: try audioURL("MALDARI_LIVE_AUDIO_24K"),
                              expectedRate: 24_000))
        print("[e2e en]\n\(describe(lines))")

        XCTAssertFalse(lines.isEmpty, "no utterance ever finalized — nothing would render")
        // The user's original report was that English "just hangs": the Korean-only
        // challenger transcribed it as Hangul gibberish and the arbiter had to throw
        // that away in favour of the segmenter's English.
        let english = try XCTUnwrap(
            lines.first { $0.sourceLanguage == .en && !$0.targetText.isEmpty },
            "English speech produced no Korean:\n" + describe(lines))
        XCTAssertEqual(ScriptDetector.language(of: english.targetText), .ko,
                       "English must come out as Korean: \(english.targetText)")
        XCTAssertFalse(TranslationFilter.isFiller(english.targetText))
    }

    /// The sentinel is an internal "nothing worth translating" marker. It reached the
    /// screen once and the user saw a column of `∅`.
    @MainActor
    func test_endToEnd_neverRendersTheEmptySentinel() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(Credentials.hasOpenAI, "no OpenAI key")
        try XCTSkipUnless(Credentials.hasAnthropic, "no Anthropic key")

        // An open mic with nothing said into it. The pipeline must produce nothing
        // at all rather than a sentinel.
        let lines = try await runSession(
            at16k: [Data](repeating: Data(repeating: 0, count: 3200), count: 10),
            at24k: [Data](repeating: Data(repeating: 0, count: 4800), count: 10))
        print("[e2e silence]\n\(describe(lines))")

        for line in lines {
            XCTAssertFalse(line.targetText.contains("∅"),
                           "the empty-translation sentinel reached the screen")
            XCTAssertFalse(line.sourceText.contains("∅"))
        }
    }

    // MARK: - Live soak: the real thing, for minutes

    /// The honest version of the memory question.
    ///
    /// `MemorySoakTests` drives a whole meeting through the pipeline in seconds, but it
    /// fakes the network and substitutes `NoopTranscriptJudge` — which excludes the two
    /// biggest per-utterance allocators in the real app: the WebSocket services with
    /// their audio buffers, and `TranscriptDebate`, which makes three LLM round trips
    /// per utterance with the rolling context in every prompt. A leak in either is
    /// invisible there and very visible in a 40-minute meeting.
    ///
    /// Opt-in twice over — `MALDARI_LIVE=1` and `MALDARI_SOAK=1` — because it bills a
    /// few minutes of two STT providers and a translator, and takes as long as it takes.
    /// `MALDARI_SOAK_SECONDS` overrides the duration.
    private final class LoopingFixtureCapture: AudioCapturing {
        private let chunks: [Data]
        private let gapChunks: Int
        private var pump: Task<Void, Never>?

        /// `gapChunks` of silence between repeats: long enough for server VAD to close
        /// each utterance, so the soak produces real finals rather than one endless one.
        init(chunks: [Data], gapChunks: Int) {
            self.chunks = chunks
            self.gapChunks = gapChunks
        }

        func start() async throws -> AsyncStream<Data> {
            let chunks = self.chunks
            let gapChunks = self.gapChunks
            return AsyncStream { continuation in
                pump = Task {
                    let silence = Data(repeating: 0, count: chunks.first?.count ?? 3200)
                    while !Task.isCancelled {
                        for chunk in chunks {
                            if Task.isCancelled { break }
                            continuation.yield(chunk)
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                        for _ in 0..<gapChunks {
                            if Task.isCancelled { break }
                            continuation.yield(silence)
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                    continuation.finish()
                }
            }
        }

        func stop() {
            pump?.cancel()
            pump = nil
        }
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    @MainActor
    func test_soak_liveSessionMemoryStaysBounded() async throws {
        try XCTSkipUnless(live, "set MALDARI_LIVE=1")
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MALDARI_SOAK"] == "1",
            "set MALDARI_SOAK=1 — this one bills several minutes of live API")
        try XCTSkipUnless(Credentials.hasOpenAI, "no OpenAI key")
        try XCTSkipUnless(Credentials.hasRTZR, "no RTZR key")
        try XCTSkipUnless(Credentials.hasAnthropic, "no Anthropic key")

        let seconds = Double(
            ProcessInfo.processInfo.environment["MALDARI_SOAK_SECONDS"] ?? "") ?? 240
        let ko16 = try chunks(from: try audioURL("MALDARI_LIVE_AUDIO_KO_16K"),
                              expectedRate: 16_000)
        let ko24 = try chunks(from: try audioURL("MALDARI_LIVE_AUDIO_KO_24K"),
                              expectedRate: 24_000)

        let settings = AppSettings.shared
        let previousMode = settings.captureModeRaw
        settings.captureModeRaw = CaptureMode.bidirectionalSingle.rawValue
        defer { settings.captureModeRaw = previousMode }

        // The real judge and the real services — that is the entire point.
        let pipeline = PipelineController()
        pipeline.makeCapture = { _, sampleRate in
            LoopingFixtureCapture(chunks: sampleRate >= 20_000 ? ko24 : ko16, gapChunks: 12)
        }

        await pipeline.start()
        try XCTSkipUnless(pipeline.isListening, "session refused to start")

        // Sample after the connections are up, so socket setup is not billed to growth.
        try await Task.sleep(nanoseconds: 15_000_000_000)
        let baseline = footprintMB()
        var trace: [String] = []

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            trace.append(String(format: "%.0fs:%.1f",
                                seconds - deadline.timeIntervalSinceNow, footprintMB()))
        }

        let finalized = pipeline.store.utterances.count
        await pipeline.stop()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = footprintMB()

        print(String(format:
            "[soak-live] %.0fs, %d utterances: %.1f MB -> %.1f MB (+%.1f MB) | %@",
            seconds, finalized, baseline, after, after - baseline,
            trace.joined(separator: " ")))

        XCTAssertGreaterThan(finalized, 0, "the soak transcribed nothing — it proved nothing")
        // Per-utterance retention is what matters, not the absolute number: a soak this
        // short cannot distinguish a 60 MB baseline from a leak, but it can measure the
        // slope. 40 MB over four minutes would be ~600 MB in an hour.
        XCTAssertLessThan(
            after - baseline, 40,
            "live memory grew \(String(format: "%.1f", after - baseline)) MB in "
            + "\(Int(seconds))s across \(finalized) utterances")
    }
}
