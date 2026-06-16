import XCTest
import AVFoundation
@testable import Translator

// MARK: - Test doubles

private actor OrderRecorder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private final class NoopTranslator: Translating {
    func streamTranslation(of korean: String, context: [TranslationPair], forbidSkip: Bool)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Emits the ∅ skip sentinel on the normal pass and a real translation only
/// when skipping is forbidden — exercises the over-skip → forced-retry guard.
private final class SkipThenTranslate: Translating {
    func streamTranslation(of korean: String, context: [TranslationPair], forbidSkip: Bool)
        -> AsyncThrowingStream<String, Error>
    {
        let text = forbidSkip ? "Forced translation." : "∅"
        return AsyncThrowingStream { c in c.yield(text); c.finish() }
    }
}

private final class MockCapture: AudioCapturing {
    private(set) var stopped = false
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

        store.beginTranslation(id: 0)
        XCTAssertEqual(store.utterances[0].state, .translating)

        store.appendTranslation(id: 0, token: "We'll look")
        store.appendTranslation(id: 0, token: " into it.")
        XCTAssertEqual(store.utterances[0].english, "We'll look into it.")

        store.endTranslation(id: 0)
        XCTAssertEqual(store.utterances[0].state, .translated)
    }

    @MainActor
    func testContextPairsReturnsLastTranslatedBeforeID() throws {
        let store = TranscriptStore()
        for seq in 0..<14 {
            store.apply(try STTMessage.decode(fixture(seq: seq, final: true, text: "문장 \(seq)")))
            store.beginTranslation(id: seq)
            store.appendTranslation(id: seq, token: "sentence \(seq)")
            store.endTranslation(id: seq)
        }
        store.apply(try STTMessage.decode(fixture(seq: 14, final: true, text: "마지막 문장")))

        let context = store.contextPairs(before: 14, limit: 10)
        XCTAssertEqual(context.count, 10)
        XCTAssertEqual(context.first?.korean, "문장 4")
        XCTAssertEqual(context.last?.english, "sentence 13")
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
            XCTAssertEqual(chunk.count, AudioChunker.chunkBytes,
                           "every non-tail chunk must be exactly 100 ms")
        }
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
        store.beginTranslation(id: 0)
        store.appendTranslation(id: 0, token: "∅")
        store.clearTranslation(id: 0)

        XCTAssertEqual(store.utterances[0].korean, "혹시 저기 그")
        XCTAssertEqual(store.utterances[0].english, "")
        XCTAssertEqual(store.utterances[0].state, .translated)

        store.apply(try STTMessage.decode(fixture(seq: 1, final: true, text: "다음 문장")))
        XCTAssertTrue(store.contextPairs(before: 1).isEmpty,
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
        let normal = ClaudeTranslationService.systemPrompt(forbidSkip: false)
        XCTAssertFalse(normal.contains("Do NOT output ∅"))
        let forced = ClaudeTranslationService.systemPrompt(forbidSkip: true)
        XCTAssertTrue(forced.contains("Do NOT output ∅"))
    }

    /// End to end: when the model emits ∅ for a substantial Korean line, the
    /// pipeline must re-translate with skipping forbidden and land a real
    /// translation — not silently drop the row.
    @MainActor
    func testSubstantialLineSkippedByModelGetsForcedRetry() async throws {
        var transcribers: [String: MockTranscriber] = [:]
        let pipeline = PipelineController(translator: SkipThenTranslate())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _ in MockCapture() }
        pipeline.makeTranscriber = { channel in
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
        pipeline.makeCapture = { _ in MockCapture() }
        pipeline.makeTranscriber = { channel in
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
        pipeline.makeCapture = { _ in capture }
        pipeline.makeTranscriber = { _ in FailingTranscriber() }

        await pipeline.start()

        // The failure → auto-stop path hops through the main actor.
        var attempts = 0
        while pipeline.isListening && attempts < 200 {
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
        let with = ClaudeTranslationService.systemPrompt(glossary: "우리회사 = OurCo")
        XCTAssertTrue(with.contains("GLOSSARY"))
        XCTAssertTrue(with.contains("우리회사 = OurCo"))

        let without = ClaudeTranslationService.systemPrompt(glossary: "   ")
        XCTAssertFalse(without.contains("GLOSSARY"))
    }

    // MARK: - Export

    @MainActor
    func testMarkdownExportFormat() throws {
        let store = TranscriptStore()
        store.startSession()
        store.apply(try STTMessage.decode(fixture(seq: 0, final: true, text: "안녕하세요")))
        store.beginTranslation(id: 0)
        store.appendTranslation(id: 0, token: "Hello everyone")
        store.endTranslation(id: 0)

        let markdown = store.exportMarkdown()
        XCTAssertTrue(markdown.contains("# Transcript"))
        XCTAssertTrue(markdown.contains("안녕하세요"))
        XCTAssertTrue(markdown.contains("> Hello everyone"))
    }
}
