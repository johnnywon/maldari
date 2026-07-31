import XCTest
import AVFoundation
@testable import Translator

// MARK: - Test doubles

private actor OrderRecorder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private final class NoopTranslator: Translating {
    func streamTranslation(
        of text: String, from source: Language, to target: Language,
        context: [TranslationPair], forbidSkip: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Emits the ∅ skip sentinel on the normal pass and a real translation only
/// when skipping is forbidden — exercises the over-skip → forced-retry guard.
private final class SkipThenTranslate: Translating {
    func streamTranslation(
        of text: String, from source: Language, to target: Language,
        context: [TranslationPair], forbidSkip: Bool
    ) -> AsyncThrowingStream<String, Error> {
        let out = forbidSkip ? "Forced translation." : "∅"
        return AsyncThrowingStream { c in c.yield(out); c.finish() }
    }
}

/// Records every direction it was asked to translate, so bidirectional routing
/// can be asserted without a network call.
private final class DirectionRecordingTranslator: Translating, @unchecked Sendable {
    private let lock = NSLock()
    private var _directions: [String] = []
    var directions: [String] {
        lock.lock(); defer { lock.unlock() }
        return _directions
    }

    func streamTranslation(
        of text: String, from source: Language, to target: Language,
        context: [TranslationPair], forbidSkip: Bool
    ) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        _directions.append("\(source.rawValue)->\(target.rawValue)")
        lock.unlock()
        return AsyncThrowingStream { c in
            c.yield(target == .en ? "translated to english" : "한국어로 번역됨")
            c.finish()
        }
    }
}

private final class MockCapture: AudioCapturing {
    private(set) var stopped = false
    let sampleRate: Double
    init(sampleRate: Double = AudioChunker.rtzrSampleRate) { self.sampleRate = sampleRate }
    func start() async throws -> AsyncStream<Data> { AsyncStream { _ in } }
    func stop() { stopped = true }
}

private final class FailingTranscriber: Transcribing {
    var onMessage: ((STTMessage) -> Void)?
    var onStateChange: ((STTConnectionState) -> Void)?
    func start(audio: AsyncStream<Data>) async {
        onStateChange?(.failed("simulated connect failure"))
    }
    func stop() async {}
}

/// Connects "successfully" and lets the test drive messages by hand.
private final class MockTranscriber: Transcribing {
    var onMessage: ((STTMessage) -> Void)?
    var onStateChange: ((STTConnectionState) -> Void)?
    private(set) var stopped = false
    func start(audio: AsyncStream<Data>) async {
        onStateChange?(.connected)
    }
    func stop() async { stopped = true }
}

/// Canned RTZR JSON fixtures fed through the real decoder + TranscriptStore,
/// asserting: partials mutate in place, finals append + trigger translation.
final class PipelineTests: XCTestCase {

    // MARK: - Fixtures (RTZR WebSocket message shape)

    private func fixture(
        seq: Int, final: Bool, text: String, confidence: Double = 0.95, duration: Int = 980
    ) -> Data {
        let json: [String: Any] = [
            "seq": seq,
            "start_at": 1200,
            "duration": duration,
            "final": final,
            "alternatives": [["text": text, "confidence": confidence]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - Decoder

    func testDecodesPartialMessage() throws {
        let message = try STTMessage.decode(fixture(seq: 0, final: false, text: "안녕하"))
        XCTAssertEqual(message.seq, 0)
        XCTAssertFalse(message.isFinal)
        XCTAssertEqual(message.bestText, "안녕하")
        XCTAssertEqual(message.alternatives.first?.confidence, 0.95)
    }

    func testDecodesFinalMessage() throws {
        let message = try STTMessage.decode(fixture(seq: 3, final: true, text: "안녕하세요 여러분"))
        XCTAssertEqual(message.seq, 3)
        XCTAssertTrue(message.isFinal)
        XCTAssertEqual(message.bestText, "안녕하세요 여러분")
    }

    func testEmptyAlternativeYieldsNilText() throws {
        let message = try STTMessage.decode(fixture(seq: 0, final: true, text: "   "))
        XCTAssertNil(message.bestText)
    }

    // MARK: - Store: partials mutate in place

    @MainActor
    func testPartialsMutateInPlace() throws {
        let store = TranscriptStore()

        store.apply(try STTMessage.decode(fixture(seq: 0, final: false, text: "안녕")))
        XCTAssertEqual(store.partials.first?.korean, "안녕")
        XCTAssertEqual(store.partials.first?.state, .partial)
        XCTAssertTrue(store.utterances.isEmpty)

        store.apply(try STTMessage.decode(fixture(seq: 0, final: false, text: "안녕하세")))
        store.apply(try STTMessage.decode(fixture(seq: 0, final: false, text: "안녕하세요")))

        // Still exactly one partial, text replaced — never appended.
        XCTAssertEqual(store.partials.count, 1)
        XCTAssertEqual(store.partials.first?.korean, "안녕하세요")
        XCTAssertEqual(store.partials.first?.id, 0)
        XCTAssertTrue(store.utterances.isEmpty)
    }

    // MARK: - Store: finals append + trigger translation

    @MainActor
    func testFinalAppendsAndTriggersTranslation() throws {
        let store = TranscriptStore()
        var finalized: [Utterance] = []
        store.onFinalized = { finalized.append($0) }

        store.apply(try STTMessage.decode(fixture(seq: 0, final: false, text: "검토해보겠")))
        store.apply(try STTMessage.decode(fixture(seq: 0, final: true, text: "검토해보겠습니다")))

        XCTAssertTrue(store.partials.isEmpty, "final must clear the pinned partial line")
        XCTAssertEqual(store.utterances.count, 1)
        XCTAssertEqual(store.utterances[0].id, 0)
        XCTAssertEqual(store.utterances[0].korean, "검토해보겠습니다")
        XCTAssertEqual(store.utterances[0].state, .finalized)

        XCTAssertEqual(finalized.count, 1, "final must fire the translation hook")
        XCTAssertEqual(finalized[0].korean, "검토해보겠습니다")
    }

    @MainActor
    func testDuplicateFinalIsIgnored() throws {
        let store = TranscriptStore()
        var finalizedCount = 0
        store.onFinalized = { _ in finalizedCount += 1 }

        store.apply(try STTMessage.decode(fixture(seq: 5, final: true, text: "네 맞습니다")))
        store.apply(try STTMessage.decode(fixture(seq: 5, final: true, text: "네 맞습니다")))

        XCTAssertEqual(store.utterances.count, 1)
        XCTAssertEqual(finalizedCount, 1)
    }

    @MainActor
    func testInterleavedSequence() throws {
        let store = TranscriptStore()
        var finalized: [Int] = []
        store.onFinalized = { finalized.append($0.id) }

        // seq 0 partial → final, then seq 1 partial → partial → final
        store.apply(try STTMessage.decode(fixture(seq: 0, final: false, text: "오늘 회의")))
        store.apply(try STTMessage.decode(fixture(seq: 0, final: true, text: "오늘 회의 시작하겠습니다")))
        store.apply(try STTMessage.decode(fixture(seq: 1, final: false, text: "광고비")))
        XCTAssertEqual(store.partials.first?.id, 1)
        store.apply(try STTMessage.decode(fixture(seq: 1, final: false, text: "광고비 정산 관련해서")))
        store.apply(try STTMessage.decode(fixture(seq: 1, final: true, text: "광고비 정산 관련해서 말씀드릴게요")))

        XCTAssertEqual(store.utterances.map(\.id), [0, 1])
        XCTAssertEqual(finalized, [0, 1])
        XCTAssertTrue(store.partials.isEmpty)
    }

    // MARK: - Store: translation streaming updates

    @MainActor
    func testTranslationLifecycle() throws {
        let store = TranscriptStore()
        store.apply(try STTMessage.decode(fixture(seq: 0, final: true, text: "검토해보겠습니다")))
        XCTAssertEqual(store.utterances[0].state, .finalized)

        store.restartTranslation(id: 0)
        store.streamTranslation(id: 0, text: "We'll look")
        XCTAssertEqual(store.utterances[0].state, .translating)

        store.streamTranslation(id: 0, text: "We'll look into it.")
        XCTAssertEqual(store.utterances[0].english, "We'll look into it.")

        store.settleTranslation(id: 0, text: "We'll look into it.")
        XCTAssertEqual(store.utterances[0].state, .translated)
        XCTAssertTrue(store.utterances[0].target.settled)
        XCTAssertEqual(store.utterances[0].target.committedCount,
                       store.utterances[0].target.words.count,
                       "settling must commit every word")
    }

    @MainActor
    func testContextPairsReturnsLastTranslatedBeforeID() throws {
        let store = TranscriptStore()
        for seq in 0..<14 {
            store.apply(try STTMessage.decode(fixture(seq: seq, final: true, text: "문장 \(seq)")))
            store.settleTranslation(id: seq, text: "sentence \(seq)")
        }
        store.apply(try STTMessage.decode(fixture(seq: 14, final: true, text: "마지막 문장")))

        let context = store.contextPairs(before: 14, from: .ko, limit: 10)
        XCTAssertEqual(context.count, 10)
        XCTAssertEqual(context.first?.source, "문장 4")
        XCTAssertEqual(context.last?.target, "sentence 13")
    }

    /// Context has to be oriented to the direction of the request being made: a
    /// KO→EN call needs Korean as the user turn, an EN→KO call the reverse.
    /// Feeding a model context backwards teaches it to translate backwards.
    @MainActor
    func testContextPairsFlipWithRequestDirection() throws {
        let store = TranscriptStore()
        store.apply(try STTMessage.decode(fixture(seq: 0, final: true, text: "정산 관련해서요")))
        store.settleTranslation(id: 0, text: "About the settlement.")
        store.apply(try STTMessage.decode(fixture(seq: 1, final: true, text: "다음")))

        let forward = store.contextPairs(before: 1, from: .ko)
        XCTAssertEqual(forward.first?.source, "정산 관련해서요")
        XCTAssertEqual(forward.first?.target, "About the settlement.")

        let reverse = store.contextPairs(before: 1, from: .en)
        XCTAssertEqual(reverse.first?.source, "About the settlement.")
        XCTAssertEqual(reverse.first?.target, "정산 관련해서요")
    }

    // MARK: - Audio conversion

    /// 1 second of 48 kHz stereo float (a typical mic/tap format) must come
    /// out as ~32 000 bytes of 16 kHz mono Int16, sliced into exact 100 ms
    /// (3 200-byte) chunks — the wire format RTZR expects.
    func testAudioChunkerResamples48kStereoFloatTo16kMonoInt16() {
        let chunker = AudioChunker()
        var chunks: [Data] = []
        chunker.onChunk = { chunks.append($0) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for _ in 0..<10 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800) else {
                return XCTFail("could not allocate test buffer")
            }
            buffer.frameLength = 4_800  // 100 ms at 48 kHz; silence is fine
            chunker.append(buffer)
        }
        chunker.flush()

        let totalBytes = chunks.reduce(0) { $0 + $1.count }
        // Ideal output: 16_000 frames × 2 bytes = 32_000 (sample-rate
        // conversion may hold back a few priming frames).
        XCTAssertGreaterThan(totalBytes, 30_000, "lost more audio than SRC priming explains")
        XCTAssertLessThanOrEqual(totalBytes, 32_400, "produced more audio than was fed in")
        XCTAssertGreaterThanOrEqual(chunks.count, 9)
        for chunk in chunks.dropLast() {
            XCTAssertEqual(chunk.count, chunker.chunkBytes,
                           "every non-tail chunk must be exactly 100 ms")
        }
    }

    /// The OpenAI Realtime API wants 24 kHz, RTZR wants 16 kHz, so the chunker's
    /// rate is per-instance. A dual-channel session runs both at once, and
    /// feeding either engine the other's rate produces transcripts that read as
    /// though the speaker were slowed down or sped up.
    func testAudioChunkerHonoursTargetSampleRate() {
        XCTAssertEqual(AudioChunker(sampleRate: AudioChunker.rtzrSampleRate).chunkBytes, 3_200)
        XCTAssertEqual(AudioChunker(sampleRate: AudioChunker.openAISampleRate).chunkBytes, 4_800)

        let chunker = AudioChunker(sampleRate: AudioChunker.openAISampleRate)
        var chunks: [Data] = []
        chunker.onChunk = { chunks.append($0) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for _ in 0..<10 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800) else {
                return XCTFail("could not allocate test buffer")
            }
            buffer.frameLength = 4_800
            chunker.append(buffer)
        }
        chunker.flush()

        let totalBytes = chunks.reduce(0) { $0 + $1.count }
        // 1s at 24 kHz mono Int16 = 48 000 bytes, less SRC priming.
        XCTAssertGreaterThan(totalBytes, 45_000)
        XCTAssertLessThanOrEqual(totalBytes, 48_600)
        for chunk in chunks.dropLast() {
            XCTAssertEqual(chunk.count, 4_800)
        }
    }

    /// The level meter is fed from the chunker rather than a second tap, because
    /// the samples are already converted and in hand there.
    func testAudioChunkerReportsRMS() {
        XCTAssertEqual(AudioChunker.rms(of: Data()), 0)
        XCTAssertEqual(AudioChunker.rms(of: Data([0, 0, 0, 0])), 0)

        // Full-scale negative samples: |−32768| / 32768 == 1.0
        var loud = Data()
        for _ in 0..<64 { loud.append(contentsOf: [0x00, 0x80]) }
        XCTAssertEqual(AudioChunker.rms(of: loud), 1.0, accuracy: 0.001)

        // Half-scale gives ~0.5.
        var half = Data()
        for _ in 0..<64 { half.append(contentsOf: [0x00, 0x40]) }
        XCTAssertEqual(AudioChunker.rms(of: half), 0.5, accuracy: 0.01)
    }

    // MARK: - Translation queue ordering

    /// At maxConcurrent 1, jobs must run strictly in submission order even
    /// when enqueued in a tight burst (regression: an unstructured-Task hop
    /// reordered them).
    @MainActor
    func testTranslationQueuePreservesFIFOOrder() async {
        let queue = TranslationQueue(maxConcurrent: 1)
        let recorder = OrderRecorder()
        let drained = expectation(description: "queue drained")

        for i in 0..<100 {
            queue.enqueue { await recorder.append(i) }
        }
        queue.enqueue { drained.fulfill() }

        await fulfillment(of: [drained], timeout: 5)
        let order = await recorder.values
        XCTAssertEqual(order, Array(0..<100))
    }

    /// At maxConcurrent 2, every job still runs exactly once and the queue
    /// drains a backlog faster than serially: two 300ms jobs must overlap.
    @MainActor
    func testTranslationQueueRunsJobsConcurrently() async {
        let queue = TranslationQueue(maxConcurrent: 2)
        let recorder = OrderRecorder()
        let drained = expectation(description: "queue drained")
        drained.expectedFulfillmentCount = 2

        let begun = Date()
        for i in 0..<2 {
            queue.enqueue {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await recorder.append(i)
                drained.fulfill()
            }
        }

        await fulfillment(of: [drained], timeout: 5)
        let elapsed = Date().timeIntervalSince(begun)
        let values = await recorder.values
        XCTAssertEqual(Set(values), Set([0, 1]), "every job must run exactly once")
        XCTAssertLessThan(elapsed, 0.55, "two 300ms jobs must overlap, not serialize")
    }

    /// Queue depth must rise on enqueue and return to zero once drained —
    /// it's the heartbeat's backlog gauge for diagnosing stalls.
    @MainActor
    func testTranslationQueueDepthTracksBacklog() async {
        let queue = TranslationQueue(maxConcurrent: 1)
        let drained = expectation(description: "queue drained")

        for _ in 0..<5 {
            queue.enqueue { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertGreaterThan(queue.depth, 0)
        queue.enqueue { drained.fulfill() }

        await fulfillment(of: [drained], timeout: 5)
        // The fulfilling job may still be decrementing; poll briefly.
        var attempts = 0
        while queue.depth > 0 && attempts < 100 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            attempts += 1
        }
        XCTAssertEqual(queue.depth, 0)
    }

    // MARK: - Filler filtering

    /// The model signals "no translatable content" with the ∅ sentinel; the
    /// legacy failure mode was a literal placeholder like "(no output -
    /// filler/incomplete thought)" leaking into the transcript AND the
    /// rolling context, teaching the model to keep emitting it.
    func testFillerFilterCatchesSentinelAndPlaceholders() {
        XCTAssertTrue(TranslationFilter.isFiller("∅"))
        XCTAssertTrue(TranslationFilter.isFiller(" ∅ \n"))
        XCTAssertTrue(TranslationFilter.isFiller(""))
        XCTAssertTrue(TranslationFilter.isFiller("(no output - filler)"))
        XCTAssertTrue(TranslationFilter.isFiller("(no output – filler/incomplete thought)"))
        XCTAssertTrue(TranslationFilter.isFiller("(No output)"))
        XCTAssertTrue(TranslationFilter.isFiller("[no translation - noise]"))
        XCTAssertTrue(TranslationFilter.isFiller("(filler)"))
    }

    func testFillerFilterPassesRealTranslations() {
        XCTAssertFalse(TranslationFilter.isFiller("Yes, sounds good."))
        XCTAssertFalse(TranslationFilter.isFiller("First, barley is included."))
        XCTAssertFalse(TranslationFilter.isFiller("No output was produced by the test run."))
        XCTAssertFalse(TranslationFilter.isFiller("We'll skip the intro and get started."))
        XCTAssertFalse(TranslationFilter.isFiller("(Laughs) that works for us."))
    }

    @MainActor
    func testClearTranslationKeepsKoreanAndExcludesFromContext() throws {
        let store = TranscriptStore()
        store.apply(try STTMessage.decode(fixture(seq: 0, final: true, text: "혹시 저기 그")))
        store.restartTranslation(id: 0)
        store.streamTranslation(id: 0, text: "∅")
        store.clearTranslation(id: 0)

        XCTAssertEqual(store.utterances[0].korean, "혹시 저기 그")
        XCTAssertEqual(store.utterances[0].english, "")
        XCTAssertEqual(store.utterances[0].state, .translated,
                       "a cleared filler row must not sit forever in .translating")

        store.apply(try STTMessage.decode(fixture(seq: 1, final: true, text: "다음 문장")))
        XCTAssertTrue(store.contextPairs(before: 1, from: .ko).isEmpty,
                      "filler rows must not enter the rolling translation context")
    }

    // MARK: - Over-skip guardrail (regression: 54% of real lines dropped as ∅)

    /// The deterministic backstop: genuine short filler/backchannels read as
    /// "no substance" (trust the model's ∅), real sentences read as substance
    /// (a ∅ there is a bug). Cases drawn from real diagnostic logs.
    func testKoreanHasSubstanceSeparatesFillerFromContent() {
        for filler in ["그", "응", "음", "으흠", "네네", "어 음 그", "그로스요머"] {
            XCTAssertFalse(TranslationFilter.koreanHasSubstance(filler),
                           "\(filler) is genuine filler — model ∅ should be trusted")
        }
        for content in [
            "음 저희가 제가 이제 SBI한테 한 300억을 받았는데",
            "예 일단은 뭐 시작 자체는 지금 다음 주부터",
            "그까 백로그잖아요 일종의 백로그",
        ] {
            XCTAssertTrue(TranslationFilter.koreanHasSubstance(content),
                          "\(content) is real content — a ∅ here must force a retry")
        }
    }

    /// The forced-retry system prompt must revoke the skip option; the normal
    /// prompt must keep it.
    func testForbidSkipPromptRemovesTheSkipOption() {
        for source in Language.allCases {
            let normal = TranslationPrompt.system(from: source, forbidSkip: false)
            XCTAssertFalse(normal.contains("Do NOT output ∅"), "\(source)")
            let forced = TranslationPrompt.system(from: source, forbidSkip: true)
            XCTAssertTrue(forced.contains("Do NOT output ∅"), "\(source)")
        }
    }

    /// Each direction must get its own prompt. The EN→KO prompt asking for
    /// English output (or vice versa) is a silent, total failure — the model
    /// happily echoes the input and the transcript looks monolingual.
    func testPromptsAreDirectionSpecific() {
        let koToEn = TranslationPrompt.system(from: .ko)
        XCTAssertTrue(koToEn.contains("into English"))
        XCTAssertTrue(koToEn.contains("ONLY the English translation"))

        let enToKo = TranslationPrompt.system(from: .en)
        XCTAssertTrue(enToKo.contains("into Korean"))
        XCTAssertTrue(enToKo.contains("ONLY the Korean translation"))

        XCTAssertNotEqual(koToEn, enToKo)
    }

    /// Prompt caching keys on the system block, and a one-hour meeting's cost
    /// depends on hitting that cache. The base prompt must be byte-stable across
    /// calls, which is also why the forced-retry text is a suffix rather than
    /// woven into the base.
    func testBasePromptIsByteStableAcrossCalls() {
        XCTAssertEqual(TranslationPrompt.base(from: .ko), TranslationPrompt.base(from: .ko))
        XCTAssertEqual(TranslationPrompt.base(from: .en), TranslationPrompt.base(from: .en))
        let withGlossary = TranslationPrompt.system(from: .ko, glossary: "가 = A")
        XCTAssertTrue(withGlossary.hasPrefix(TranslationPrompt.base(from: .ko)),
                      "the cacheable base must remain a prefix of the assembled prompt")
    }

    /// End to end: when the model emits ∅ for a substantial Korean line, the
    /// pipeline must re-translate with skipping forbidden and land a real
    /// translation — not silently drop the row.
    @MainActor
    func testSubstantialLineSkippedByModelGetsForcedRetry() async throws {
        var transcribers: [String: MockTranscriber] = [:]
        let pipeline = PipelineController(translator: SkipThenTranslate())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, rate in MockCapture(sampleRate: rate) }
        pipeline.makeTranscriber = { _, _, channel in
            let t = MockTranscriber(); transcribers[channel] = t; return t
        }

        await pipeline.start()
        transcribers["main"]?.onMessage?(try STTMessage.decode(
            fixture(seq: 0, final: true, text: "근데 그건 사실 좀 다른 얘기인데요")))

        var attempts = 0
        while pipeline.store.utterances.first?.state != .translated && attempts < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000); attempts += 1
        }

        let u = try XCTUnwrap(pipeline.store.utterances.first)
        XCTAssertEqual(u.english, "Forced translation.",
                       "a ∅ on substantial Korean must force a retry, not drop the line")
        XCTAssertEqual(u.state, .translated)
        await pipeline.stop()
    }

    /// The flip side: a genuinely short filler line the model ∅s stays dropped
    /// — no wasteful forced retry, Korean-only row as before.
    @MainActor
    func testShortFillerSkippedByModelStaysDropped() async throws {
        var transcribers: [String: MockTranscriber] = [:]
        let pipeline = PipelineController(translator: SkipThenTranslate())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, rate in MockCapture(sampleRate: rate) }
        pipeline.makeTranscriber = { _, _, channel in
            let t = MockTranscriber(); transcribers[channel] = t; return t
        }

        await pipeline.start()
        transcribers["main"]?.onMessage?(try STTMessage.decode(
            fixture(seq: 0, final: true, text: "응")))

        var attempts = 0
        while pipeline.store.utterances.first?.state != .translated && attempts < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000); attempts += 1
        }

        let u = try XCTUnwrap(pipeline.store.utterances.first)
        XCTAssertEqual(u.korean, "응")
        XCTAssertEqual(u.english, "", "short genuine filler stays dropped (no forced retry)")
        XCTAssertEqual(u.state, .translated)
        await pipeline.stop()
    }

    // MARK: - Pipeline failure handling

    /// When the STT layer fails, the pipeline must tear down capture
    /// (otherwise audio buffers unboundedly into a stream nobody consumes)
    /// and keep the failure visible.
    @MainActor
    func testPipelineAutoStopsAndCleansUpOnSTTFailure() async {
        let pipeline = PipelineController(translator: NoopTranslator())
        let capture = MockCapture()
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, _ in capture }
        pipeline.makeTranscriber = { _, _, _ in FailingTranscriber() }

        await pipeline.start()

        // The failure → auto-stop path hops through the main actor. Wait for the
        // *teardown*, not just the flag: `isListening` is now cleared at the top of
        // stop() rather than the bottom (so a second stop() cannot pass the guard
        // and dismantle a concurrent start), which means the flag flips before the
        // captures have actually been torn down.
        var attempts = 0
        while !(!pipeline.isListening && capture.stopped) && attempts < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            attempts += 1
        }

        XCTAssertFalse(pipeline.isListening, "pipeline must auto-stop on STT failure")
        XCTAssertTrue(capture.stopped, "capture must be torn down on STT failure")
        XCTAssertNotNil(pipeline.lastError)
        if case .failed = pipeline.connectionState {} else {
            XCTFail("failed state should stay visible after auto-stop, got \(pipeline.connectionState)")
        }
    }

    /// The status dot shows one state for N channels: the worst one wins.
    func testMergedConnectionState() {
        XCTAssertEqual(PipelineController.mergedState([.connected, .connected]), .connected)
        XCTAssertEqual(PipelineController.mergedState([.connected, .connecting]), .connecting)
        XCTAssertEqual(
            PipelineController.mergedState([.connected, .reconnecting(attempt: 2)]),
            .reconnecting(attempt: 2))
        XCTAssertEqual(
            PipelineController.mergedState([.failed("boom"), .connected]), .failed("boom"))
        XCTAssertEqual(PipelineController.mergedState([.idle, .connected]), .connecting)
        XCTAssertEqual(PipelineController.mergedState([]), .idle)
    }

    // MARK: - Test isolation (regression: tests leaked into ~/Library + prod cloud)

    /// Running `swift test` must NEVER touch the real user environment or the
    /// live cloud. Before the fix, the pipeline failure test drove
    /// SessionRecorder → CloudSyncService and uploaded a test session to
    /// production maldari.johnnywon.com, and wrote logs/recordings into the
    /// real ~/Library/{Logs,Application Support}/Maldari.
    func testTestRunsAreIsolatedFromRealEnvironment() {
        XCTAssertTrue(AppEnvironment.isTesting, "must detect we're running under XCTest")
        XCTAssertFalse(
            SessionRecorder.sessionsRoot.path.contains("Application Support/Maldari"),
            "session recordings must not land in the real user directory under test")
        XCTAssertFalse(
            DiagnosticLog.directory.path.contains("Library/Logs/Maldari"),
            "diagnostic logs must not land in the real user directory under test")
    }

    // MARK: - Cloud sync wire format

    func testCloudSyncRequestFormat() throws {
        let payload = CloudSyncService.Payload(
            sessionID: "2026-06-11-120154",
            markdown: "# Transcript\n",
            startedAt: Date(timeIntervalSince1970: 1_781_000_000),
            utterances: 42,
            durationS: 360,
            finalized: true)
        let request = try XCTUnwrap(CloudSyncService.makeRequest(
            endpoint: "https://maldari.johnnywon.com/", token: "tok", payload: payload))

        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://maldari.johnnywon.com/api/sessions/2026-06-11-120154")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-maldari-utterances"), "42")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-maldari-duration"), "360")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-maldari-finalized"), "true")
        XCTAssertEqual(request.httpBody, Data("# Transcript\n".utf8))
    }

    func testCloudSyncRejectsBadEndpoint() {
        let payload = CloudSyncService.Payload(
            sessionID: "x", markdown: "m", startedAt: Date(),
            utterances: 0, durationS: 0, finalized: false)
        XCTAssertNil(CloudSyncService.makeRequest(endpoint: "not a url", token: "t", payload: payload))
    }

    // MARK: - Glossary prompt assembly

    func testSystemPromptIncludesGlossaryOnlyWhenPresent() {
        let with = TranslationPrompt.system(from: .ko, glossary: "우리회사 = OurCo")
        XCTAssertTrue(with.contains("GLOSSARY"))
        XCTAssertTrue(with.contains("우리회사 = OurCo"))

        let without = TranslationPrompt.system(from: .ko, glossary: "   ")
        XCTAssertFalse(without.contains("GLOSSARY"))
    }

    // MARK: - Export

    @MainActor
    func testMarkdownExportFormat() throws {
        let store = TranscriptStore()
        store.startSession()
        store.apply(try STTMessage.decode(fixture(seq: 0, final: true, text: "안녕하세요")))
        store.settleTranslation(id: 0, text: "Hello everyone")

        let markdown = store.exportMarkdown()
        XCTAssertTrue(markdown.contains("# Transcript"))
        XCTAssertTrue(markdown.contains("안녕하세요"))
        XCTAssertTrue(markdown.contains("> Hello everyone"))
    }

    /// A bilingual transcript loses who-spoke-what unless the direction is
    /// recorded: Korean always sits above English in the export regardless of
    /// which was spoken, so the KO/EN marker is the only carrier.
    @MainActor
    func testMarkdownExportMarksDirection() throws {
        let store = TranscriptStore()
        store.startSession()
        store.apply(STTMessage(seq: 0, duration: 900, isFinal: true,
                               text: "단가를 맞추기 어렵습니다", engine: .rtzr, language: .ko))
        store.settleTranslation(id: 0, text: "We can't meet that unit price.")
        store.apply(STTMessage(seq: 1, duration: 900, isFinal: true,
                               text: "Could you send the breakdown?",
                               engine: .openai, language: .en))
        store.settleTranslation(id: 1, text: "내역서를 보내주시겠습니까?")

        let markdown = store.exportMarkdown()
        XCTAssertTrue(markdown.contains("· KO"), "Korean-spoken rows must be marked")
        XCTAssertTrue(markdown.contains("· EN"), "English-spoken rows must be marked")
        // Korean stays in the Korean slot and English in the English slot, both
        // directions — the whole reason the fields are language-named.
        XCTAssertTrue(markdown.contains("단가를 맞추기 어렵습니다"))
        XCTAssertTrue(markdown.contains("> We can't meet that unit price."))
        XCTAssertTrue(markdown.contains("내역서를 보내주시겠습니까?"))
        XCTAssertTrue(markdown.contains("> Could you send the breakdown?"))
    }

    // MARK: - Bidirectional routing

    /// An English-spoken utterance must translate EN→KO and land its Korean in
    /// the `korean` field, not overwrite the English source. Getting this
    /// backwards is silent: the row still looks populated.
    @MainActor
    func testEnglishSourceTranslatesToKoreanAndKeepsFieldsStraight() async throws {
        var transcribers: [String: MockTranscriber] = [:]
        let translator = DirectionRecordingTranslator()
        let pipeline = PipelineController(translator: translator, judge: NoopTranscriptJudge())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, rate in MockCapture(sampleRate: rate) }
        pipeline.makeTranscriber = { _, _, channel in
            let t = MockTranscriber(); transcribers[channel] = t; return t
        }
        // Must be a bidirectional mode: `koreanOnly` deliberately pins its single
        // channel to Korean, so an English message there is correctly relabelled.
        AppSettings.shared.captureModeRaw = CaptureMode.bidirectionalSingle.rawValue
        defer { AppSettings.shared.captureModeRaw = CaptureMode.koreanOnly.rawValue }
        // Speculation would fire extra passes and pollute `directions`.
        let wasSpeculative = AppSettings.shared.speculativeTranslation
        AppSettings.shared.speculativeTranslation = false
        defer { AppSettings.shared.speculativeTranslation = wasSpeculative }

        await pipeline.start()
        // The segmenter owns utterance boundaries in single-mic bidirectional mode.
        transcribers["segmenter"]?.onMessage?(STTMessage(
            seq: 0, duration: 900, isFinal: true,
            text: "Could you send that breakdown by Friday?",
            engine: .openai, language: .en))

        var attempts = 0
        while pipeline.store.utterances.first?.state != .translated && attempts < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000); attempts += 1
        }

        let u = try XCTUnwrap(pipeline.store.utterances.first)
        XCTAssertEqual(u.sourceLanguage, .en)
        XCTAssertEqual(u.english, "Could you send that breakdown by Friday?",
                       "the spoken English must stay in the english field")
        XCTAssertEqual(u.korean, "한국어로 번역됨",
                       "the translation must land in the korean field")
        XCTAssertEqual(u.sourceText, u.english)
        XCTAssertEqual(u.targetText, u.korean)
        XCTAssertTrue(translator.directions.contains("en->ko"),
                      "expected an EN→KO request, got \(translator.directions)")
        await pipeline.stop()
    }

    /// Dual-channel mode is the first thing to ever run two channels, so the
    /// 1M-apart id bands that `channelIDStride` reserves have never actually
    /// been exercised. Two engines both starting their seq at 0 must not collide.
    @MainActor
    func testDualChannelIDBandsDoNotCollide() async throws {
        var transcribers: [String: MockTranscriber] = [:]
        let pipeline = PipelineController(
            translator: DirectionRecordingTranslator(), judge: NoopTranscriptJudge())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, rate in MockCapture(sampleRate: rate) }
        pipeline.makeTranscriber = { _, _, channel in
            let t = MockTranscriber(); transcribers[channel] = t; return t
        }
        AppSettings.shared.captureModeRaw = CaptureMode.bidirectionalDual.rawValue
        defer { AppSettings.shared.captureModeRaw = CaptureMode.koreanOnly.rawValue }

        await pipeline.start()
        XCTAssertEqual(Set(transcribers.keys), ["guests", "operator"],
                       "dual mode must spawn exactly two named channels")

        // Both engines restart seq at 0 for their own stream.
        transcribers["guests"]?.onMessage?(STTMessage(
            seq: 0, duration: 900, isFinal: true, text: "네 확인했습니다", engine: .rtzr))
        transcribers["operator"]?.onMessage?(STTMessage(
            seq: 0, duration: 900, isFinal: true, text: "Understood, thank you.", engine: .openai))

        var attempts = 0
        while pipeline.store.utterances.count < 2 && attempts < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000); attempts += 1
        }

        XCTAssertEqual(pipeline.store.utterances.count, 2,
                       "both channels' utterances must survive — no id collision")
        let ids = Set(pipeline.store.utterances.map(\.id))
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains(0))
        XCTAssertTrue(ids.contains(PipelineController.channelIDStride),
                      "the second channel must land in its own id band")
        XCTAssertEqual(Set(pipeline.store.utterances.map(\.sourceLanguage)), [.ko, .en],
                       "each channel's pinned language must reach the store")
        await pipeline.stop()
    }
}

// MARK: - Commit carry-over across finalization

/// Words committed while a sentence was still a hypothesis must stay committed
/// once it finalizes. Without this the translation visibly resets to grey the
/// instant the speaker stops talking — the exact flicker prefix consensus exists
/// to prevent.
extension PipelineTests {

    @MainActor
    func testCommittedWordsSurviveFinalization() throws {
        let store = TranscriptStore()

        // Hypothesis grows; two consecutive speculative passes agree on a prefix.
        store.apply(STTMessage(seq: 0, isFinal: false, text: "먼저 초기", engine: .rtzr, language: .ko))
        store.applyPartialSpeculative(seq: 0, revision: 0, text: "First, the initial order")
        store.apply(STTMessage(seq: 0, isFinal: false, text: "먼저 초기 발주 수량에", engine: .rtzr, language: .ko))
        store.applyPartialSpeculative(seq: 0, revision: 1, text: "First, the initial order quantity")

        let carried = try XCTUnwrap(store.currentPartial).target
        XCTAssertGreaterThan(carried.committedCount, 0,
                             "two agreeing passes must commit a prefix")

        // Sentence locks.
        store.apply(STTMessage(seq: 0, duration: 900, isFinal: true,
                               text: "먼저 초기 발주 수량에 대해 말씀드리겠습니다",
                               engine: .rtzr, language: .ko))
        XCTAssertEqual(store.utterances[0].target.committedCount, carried.committedCount,
                       "the commit frontier must carry onto the finalized utterance")

        // The final translation pass streams in from empty, then settles. This is
        // the first pass, so it uses beginTranslationPass — restartTranslation is
        // only for the forced retry, and would discard the frontier.
        store.beginTranslationPass(id: 0)
        for prefix in ["First,", "First, let", "First, let me address the initial order quantity."] {
            store.streamTranslation(id: 0, text: prefix)
        }
        XCTAssertGreaterThanOrEqual(
            store.utterances[0].target.committedCount, carried.committedCount,
            "a fresh streaming pass must not destroy the carried commit frontier")
        // And the words on screen never drop back to grey while it streams.
        XCTAssertFalse(store.utterances[0].target.committed.isEmpty,
                       "committed words must stay accented through the final pass")

        store.settleTranslation(id: 0, text: "First, let me address the initial order quantity.")
        XCTAssertTrue(store.utterances[0].target.settled)
        XCTAssertEqual(store.utterances[0].english,
                       "First, let me address the initial order quantity.")
    }

    /// The forced retry is the one case that MUST discard the frontier: it is
    /// re-translating the same source from scratch after a wrong ∅, so nothing
    /// committed from the discarded attempt can be trusted.
    @MainActor
    func testForcedRetryDiscardsTheCommitFrontier() throws {
        let store = TranscriptStore()
        store.apply(STTMessage(seq: 0, duration: 900, isFinal: true,
                               text: "근데 그건 사실 좀 다른 얘기인데요", engine: .rtzr, language: .ko))
        store.beginTranslationPass(id: 0)
        store.streamTranslation(id: 0, text: "But that's a different matter")
        store.settleTranslation(id: 0, text: "But that's a different matter")
        XCTAssertGreaterThan(store.utterances[0].target.committedCount, 0)

        store.restartTranslation(id: 0)
        XCTAssertEqual(store.utterances[0].target.committedCount, 0)
        XCTAssertTrue(store.utterances[0].target.isEmpty)
        XCTAssertFalse(store.utterances[0].target.settled,
                       "a retry must re-open the target for a second pass")
    }
}

// MARK: - Arbitration routing

extension PipelineTests {

    /// In single-mic bidirectional mode the RTZR challenger must NOT be pinned to
    /// Korean. Pinning tells the arbiter "RTZR is confident this is Korean" about
    /// a transcript that is actually Hangul gibberish approximating English
    /// phonemes, which is precisely the signal the cross-language rule needs to
    /// see. The English speaker then wins on merit rather than by accident.
    @MainActor
    func testEnglishSpeechInSingleMicPrefersTheGeneralistEngine() async throws {
        var transcribers: [String: MockTranscriber] = [:]
        let pipeline = PipelineController(
            translator: DirectionRecordingTranslator(), judge: NoopTranscriptJudge())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, rate in MockCapture(sampleRate: rate) }
        pipeline.makeTranscriber = { _, _, channel in
            let t = MockTranscriber(); transcribers[channel] = t; return t
        }
        AppSettings.shared.captureModeRaw = CaptureMode.bidirectionalSingle.rawValue
        let wasSpeculative = AppSettings.shared.speculativeTranslation
        AppSettings.shared.speculativeTranslation = false
        defer {
            AppSettings.shared.captureModeRaw = CaptureMode.koreanOnly.rawValue
            AppSettings.shared.speculativeTranslation = wasSpeculative
        }

        await pipeline.start()
        XCTAssertEqual(Set(transcribers.keys), ["segmenter", "challenger"])

        // RTZR hears English and produces Hangul approximating the sounds.
        transcribers["challenger"]?.onMessage?(STTMessage(
            seq: 0, duration: 900, isFinal: true,
            text: "쿠쥬 센드 댓 브레이크다운", engine: .rtzr))
        // OpenAI hears the same speech correctly.
        transcribers["segmenter"]?.onMessage?(STTMessage(
            seq: 0, duration: 900, isFinal: true,
            text: "Could you send that breakdown?", engine: .openai, language: .en))

        var attempts = 0
        while pipeline.store.utterances.isEmpty && attempts < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000); attempts += 1
        }

        let u = try XCTUnwrap(pipeline.store.utterances.first)
        XCTAssertEqual(u.sourceLanguage, .en,
                       "the generalist's English must win over the specialist's gibberish")
        XCTAssertEqual(u.english, "Could you send that breakdown?")
        XCTAssertEqual(pipeline.store.utterances.count, 1,
                       "the challenger must not create an utterance of its own")
        await pipeline.stop()
    }

    /// Korean speech in the same mode must go the other way: both engines agree
    /// on the language, so the Korean specialist wins.
    @MainActor
    func testKoreanSpeechInSingleMicPrefersTheSpecialistEngine() async throws {
        var transcribers: [String: MockTranscriber] = [:]
        let pipeline = PipelineController(
            translator: DirectionRecordingTranslator(), judge: NoopTranscriptJudge())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, rate in MockCapture(sampleRate: rate) }
        pipeline.makeTranscriber = { _, _, channel in
            let t = MockTranscriber(); transcribers[channel] = t; return t
        }
        AppSettings.shared.captureModeRaw = CaptureMode.bidirectionalSingle.rawValue
        let wasSpeculative = AppSettings.shared.speculativeTranslation
        AppSettings.shared.speculativeTranslation = false
        defer {
            AppSettings.shared.captureModeRaw = CaptureMode.koreanOnly.rawValue
            AppSettings.shared.speculativeTranslation = wasSpeculative
        }

        await pipeline.start()
        // Identical text from both engines — no divergence, so no judge needed.
        let korean = "금형 비용은 별도로 청구됩니다"
        transcribers["challenger"]?.onMessage?(STTMessage(
            seq: 0, duration: 900, isFinal: true, text: korean, confidence: 0.97, engine: .rtzr))
        transcribers["segmenter"]?.onMessage?(STTMessage(
            seq: 0, duration: 900, isFinal: true, text: korean,
            confidence: 0.9, engine: .openai, language: .ko))

        var attempts = 0
        while pipeline.store.utterances.isEmpty && attempts < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000); attempts += 1
        }

        let u = try XCTUnwrap(pipeline.store.utterances.first)
        XCTAssertEqual(u.sourceLanguage, .ko)
        XCTAssertEqual(u.korean, korean)
        await pipeline.stop()
    }
}
