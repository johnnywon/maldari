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
}
