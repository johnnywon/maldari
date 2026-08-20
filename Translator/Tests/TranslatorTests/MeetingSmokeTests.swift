import XCTest
@testable import Translator

/// End-to-end: a scripted bilingual meeting driven through the real
/// PipelineController, TranscriptStore, ArbitrationCoordinator and consensus
/// machinery, with only the network boundaries mocked.
///
/// The unit tests cover each rule in isolation. This covers the thing that
/// actually matters and that no unit test can: that a meeting goes in one end and
/// a complete, correctly-attributed bilingual transcript comes out the other.
@MainActor
final class MeetingSmokeTests: XCTestCase {

    // MARK: - Doubles

    /// Translates by lookup, so assertions can be exact. Falls back to a marker
    /// that makes an unexpected request obvious rather than silently plausible.
    private final class ScriptedTranslator: Translating, @unchecked Sendable {
        private let lock = NSLock()
        private var table: [String: String]
        private(set) var requests: [(String, Language, Language)] = []

        init(_ table: [String: String]) { self.table = table }

        func streamTranslation(
            of text: String, from source: Language, to target: Language,
            context: [TranslationPair], forbidSkip: Bool
        ) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            requests.append((text, source, target))
            let answer = table[text] ?? "<<untranslated:\(text)>>"
            lock.unlock()
            return AsyncThrowingStream { continuation in
                // Stream in a few chunks so the streaming path is exercised, not
                // just a single atomic yield.
                var sent = ""
                for word in answer.split(separator: " ") {
                    sent += (sent.isEmpty ? "" : " ") + word
                    continuation.yield(sent == answer ? String(word) : String(word) + " ")
                }
                continuation.finish()
            }
        }

        var requestedDirections: [String] {
            lock.lock(); defer { lock.unlock() }
            return requests.map { "\($0.1.rawValue)->\($0.2.rawValue)" }
        }
    }

    private final class Wire: Transcribing {
        var onMessage: ((STTMessage) -> Void)?
        var onStateChange: ((STTConnectionState) -> Void)?
        func start(audio: AsyncStream<Data>) async { onStateChange?(.connected) }
        func stop() async {}
    }

    private final class SilentCapture: AudioCapturing {
        func start() async throws -> AsyncStream<Data> { AsyncStream { _ in } }
        func stop() {}
    }

    private func waitUntil(
        _ label: String, timeout: TimeInterval = 4,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(label)"); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - The meeting

    func test_bilingualMeeting_producesACompleteCorrectlyAttributedTranscript() async throws {
        let translator = ScriptedTranslator([
            "5천 대 기준으로는 단가를 맞추기 어렵습니다":
                "At five thousand units we can't meet that unit price.",
            "What if we committed to eight thousand for the first quarter?":
                "1분기에 8천 대를 확정하면 어떻겠습니까?",
            "다만 금형 비용은 별도로 청구됩니다":
                "However, the tooling cost is billed separately.",
            // Pure filler: the model answers with the skip sentinel.
            "네네": TranslationFilter.sentinel,
        ])

        var wires: [String: Wire] = [:]
        let pipeline = PipelineController(translator: translator, judge: NoopTranscriptJudge())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, _ in SilentCapture() }
        pipeline.makeTranscriber = { _, _, channel in
            let w = Wire(); wires[channel] = w; return w
        }

        let settings = AppSettings.shared
        let previousMode = settings.captureModeRaw
        let previousSpeculative = settings.speculativeTranslation
        settings.captureModeRaw = CaptureMode.bidirectionalSingle.rawValue
        // Speculation off: it fires extra passes whose exact count depends on
        // wall-clock timing, which would make this test flaky. Speculation has its
        // own deterministic coverage in PipelineTests.
        settings.speculativeTranslation = false
        defer {
            settings.captureModeRaw = previousMode
            settings.speculativeTranslation = previousSpeculative
        }

        await pipeline.start()
        let segmenter = try XCTUnwrap(wires["segmenter"])
        let challenger = try XCTUnwrap(wires["challenger"])

        // ── 1. Korean guest. Both engines agree, so the specialist's text stands.
        let korean1 = "5천 대 기준으로는 단가를 맞추기 어렵습니다"
        challenger.onMessage?(STTMessage(
            seq: 0, duration: 3_000, isFinal: true, text: korean1,
            confidence: 0.97, engine: .rtzr))
        segmenter.onMessage?(STTMessage(
            seq: 0, duration: 3_000, isFinal: true, text: korean1,
            confidence: 0.9, engine: .openai, language: .ko))
        try await waitUntil("first Korean line translated") {
            pipeline.store.utterances.first(where: { $0.korean == korean1 })?.state == .translated
        }

        // ── 2. English operator. RTZR emits Hangul gibberish; the generalist wins.
        let english = "What if we committed to eight thousand for the first quarter?"
        challenger.onMessage?(STTMessage(
            seq: 1, duration: 2_500, isFinal: true,
            text: "왓 이프 위 커미티드 투 에잇 사우전드", engine: .rtzr))
        segmenter.onMessage?(STTMessage(
            seq: 1, duration: 2_500, isFinal: true, text: english,
            confidence: 0.95, engine: .openai, language: .en))
        try await waitUntil("English line translated") {
            pipeline.store.utterances.first(where: { $0.english == english })?.state == .translated
        }

        // ── 3. Long Korean run: RTZR forces finals every 5s, OpenAI makes one
        //      segment. All challenger fragments must be matched, and the full
        //      utterance must survive.
        let korean2 = "다만 금형 비용은 별도로 청구됩니다"
        challenger.onMessage?(STTMessage(
            seq: 2, duration: 5_000, isFinal: true, text: "다만 금형", engine: .rtzr))
        challenger.onMessage?(STTMessage(
            seq: 3, duration: 3_000, isFinal: true, text: "비용은 별도로 청구됩니다", engine: .rtzr))
        segmenter.onMessage?(STTMessage(
            seq: 2, duration: 8_000, isFinal: true, text: korean2,
            confidence: 0.92, engine: .openai, language: .ko))
        try await waitUntil("long Korean line translated") {
            pipeline.store.utterances.first(where: { $0.korean == korean2 })?.state == .translated
        }

        // ── 4. Pure filler. The model skips it; the row keeps its Korean and
        //      shows no translation, and must not sit in .translating forever.
        challenger.onMessage?(STTMessage(
            seq: 4, duration: 400, isFinal: true, text: "네네", confidence: 0.8, engine: .rtzr))
        segmenter.onMessage?(STTMessage(
            seq: 3, duration: 400, isFinal: true, text: "네네",
            confidence: 0.8, engine: .openai, language: .ko))
        try await waitUntil("filler row resolved") {
            pipeline.store.utterances.first(where: { $0.korean == "네네" })?.state == .translated
        }

        // ── Assertions on the finished transcript ────────────────────────────
        let all = pipeline.store.utterances
        XCTAssertEqual(all.count, 4, "every utterance must survive: \(all.map(\.sourceText))")

        let first = try XCTUnwrap(all.first { $0.korean == korean1 })
        XCTAssertEqual(first.sourceLanguage, .ko)
        XCTAssertEqual(first.english, "At five thousand units we can't meet that unit price.")

        let second = try XCTUnwrap(all.first { $0.english == english })
        XCTAssertEqual(second.sourceLanguage, .en, "the generalist's English must win")
        XCTAssertEqual(second.korean, "1분기에 8천 대를 확정하면 어떻겠습니까?",
                       "an English-spoken line's translation belongs in the korean field")

        let third = try XCTUnwrap(all.first { $0.korean == korean2 })
        XCTAssertEqual(third.sourceLanguage, .ko)
        XCTAssertEqual(third.english, "However, the tooling cost is billed separately.")

        let filler = try XCTUnwrap(all.first { $0.korean == "네네" })
        XCTAssertEqual(filler.english, "", "filler must render source-only")
        XCTAssertEqual(filler.state, .translated)

        // Both directions were actually requested, and nothing was translated
        // backwards.
        let directions = translator.requestedDirections
        XCTAssertTrue(directions.contains("ko->en"), "\(directions)")
        XCTAssertTrue(directions.contains("en->ko"), "\(directions)")
        XCTAssertFalse(directions.isEmpty)

        // No source text was ever handed to the translator in the wrong direction.
        for (text, source, _) in translator.requests {
            let detected = ScriptDetector.language(of: text)
            if let detected {
                XCTAssertEqual(detected, source,
                               "translated \(text.prefix(30))… as \(source.rawValue)")
            }
        }

        // Every utterance reached the transcript of record, so the Presentation
        // window's completion rule can fire in every mode.
        for u in all {
            XCTAssertEqual(u.sourceState, .arbitrated,
                           "\(u.sourceText.prefix(20))… never became the record")
        }

        // The export carries both languages and marks who spoke which.
        let markdown = pipeline.store.exportMarkdown()
        XCTAssertTrue(markdown.contains("· KO"))
        XCTAssertTrue(markdown.contains("· EN"))
        for u in all where !u.korean.isEmpty {
            XCTAssertTrue(markdown.contains(u.korean), "export lost \(u.korean)")
        }
        for u in all where !u.english.isEmpty {
            XCTAssertTrue(markdown.contains(u.english), "export lost \(u.english)")
        }

        // Stop must let the in-flight tail land before the recorder closes.
        await pipeline.stop()
        XCTAssertFalse(pipeline.isListening)
        XCTAssertEqual(pipeline.audioLevel, 0, "the meter must go quiet on stop")
    }

    /// The default mode must keep behaving exactly as it did before any of this:
    /// one engine, Korean in, English out, no arbitration.
    func test_koreanOnlyMode_isUnchanged() async throws {
        let translator = ScriptedTranslator([
            "오늘 회의 시작하겠습니다": "Let's begin today's meeting.",
        ])
        var wires: [String: Wire] = [:]
        let pipeline = PipelineController(translator: translator, judge: NoopTranscriptJudge())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, _ in SilentCapture() }
        pipeline.makeTranscriber = { _, _, channel in
            let w = Wire(); wires[channel] = w; return w
        }

        let settings = AppSettings.shared
        let previousMode = settings.captureModeRaw
        let previousSpeculative = settings.speculativeTranslation
        settings.captureModeRaw = CaptureMode.koreanOnly.rawValue
        settings.speculativeTranslation = false
        defer {
            settings.captureModeRaw = previousMode
            settings.speculativeTranslation = previousSpeculative
        }

        await pipeline.start()
        XCTAssertEqual(Set(wires.keys), ["main"], "koreanOnly must run exactly one channel")

        wires["main"]?.onMessage?(STTMessage(
            seq: 0, duration: 2_000, isFinal: true, text: "오늘 회의 시작하겠습니다",
            confidence: 0.96, engine: .rtzr))
        try await waitUntil("translated") {
            pipeline.store.utterances.first?.state == .translated
        }

        let u = try XCTUnwrap(pipeline.store.utterances.first)
        XCTAssertEqual(u.sourceLanguage, .ko)
        XCTAssertEqual(u.korean, "오늘 회의 시작하겠습니다")
        XCTAssertEqual(u.english, "Let's begin today's meeting.")
        XCTAssertEqual(translator.requestedDirections, ["ko->en"])
        await pipeline.stop()
    }
}
