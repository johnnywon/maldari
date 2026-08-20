import XCTest
import Observation
@testable import Translator

/// Translation tokens are written to the store at display rate, not at the rate the
/// provider emits them.
///
/// Every write invalidates Observation, and SwiftUI answers by re-laying-out the
/// Presentation window — whose live row is deliberately enormous text. A provider
/// streaming 30-50 tokens a second therefore drove that many full re-layouts a second,
/// per concurrent stream, with up to four running at once. That is what made the
/// pointer stutter during a real meeting.
///
/// Throttling is only safe because these writes are **absolute, not incremental**: each
/// carries the whole accumulated string, so a dropped value is one the next write fully
/// supersedes. This file pins both halves of that contract — the rate is bounded, and
/// the text still arrives complete. If someone later changes the streaming protocol to
/// send deltas instead, the second test here fails, which is the point.
@MainActor
final class StreamCoalescingTests: XCTestCase {

    /// Emits every word as its own token with no delay, which is the adversarial case:
    /// tokens arrive far faster than the display can use them.
    private final class BurstTranslator: Translating, @unchecked Sendable {
        let answer: String
        private let lock = NSLock()
        private var _tokensEmitted = 0
        var tokensEmitted: Int {
            lock.lock(); defer { lock.unlock() }
            return _tokensEmitted
        }

        init(answer: String) { self.answer = answer }

        func streamTranslation(
            of text: String, from source: Language, to target: Language,
            context: [TranslationPair], forbidSkip: Bool
        ) -> AsyncThrowingStream<String, Error> {
            let words = answer.split(separator: " ").map(String.init)
            return AsyncThrowingStream { continuation in
                for (i, word) in words.enumerated() {
                    continuation.yield(i == 0 ? word : " " + word)
                    self.lock.lock(); self._tokensEmitted += 1; self.lock.unlock()
                }
                continuation.finish()
            }
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

    private final class Counter: @unchecked Sendable { var n = 0 }

    private func waitUntil(
        _ label: String, timeout: TimeInterval = 6, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(label)"); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A 240-word translation, long enough that a per-token write rate is obviously
    /// distinguishable from a display-rate one.
    private let answer = (0..<240)
        .map { "word\($0)" }
        .joined(separator: " ")

    private func runOneUtterance(
        _ body: @MainActor (PipelineController, Wire) async throws -> Void
    ) async throws -> (pipeline: PipelineController, translator: BurstTranslator) {
        let translator = BurstTranslator(answer: answer)
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
        // Speculation off: it would add passes whose count depends on wall-clock
        // timing, and this test is about the write rate of one stream.
        settings.speculativeTranslation = false
        defer {
            settings.captureModeRaw = previousMode
            settings.speculativeTranslation = previousSpeculative
        }

        await pipeline.start()
        let wire = try XCTUnwrap(wires["main"])
        try await body(pipeline, wire)
        await pipeline.stop()
        return (pipeline, translator)
    }

    // MARK: - Lossless

    func test_theFullTranslationArrivesDespiteThrottling() async throws {
        let result = try await runOneUtterance { pipeline, wire in
            wire.onMessage?(STTMessage(
                seq: 0, duration: 2_000, isFinal: true, text: "안녕하세요",
                confidence: 0.95, engine: .rtzr))
            try await self.waitUntil("translated") {
                pipeline.store.utterances.first?.state == .translated
            }
        }

        let landed = try XCTUnwrap(result.pipeline.store.utterances.first)
        XCTAssertEqual(landed.english, answer,
                       "throttling dropped text — these writes are supposed to be absolute")
        XCTAssertEqual(result.translator.tokensEmitted, 240)
    }

    // MARK: - Bounded

    /// The property that fixes the stutter: the number of times the UI is asked to
    /// re-render must track the DISPLAY rate, not the token rate.
    func test_writeCountTracksDisplayRateNotTokenRate() async throws {
        let translator = BurstTranslator(answer: answer)
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
        let wire = try XCTUnwrap(wires["main"])
        let store = pipeline.store

        // Count Observation invalidations of `utterances` — the same signal SwiftUI
        // acts on. Re-armed synchronously from `onChange`, which is delivered inline
        // from the mutation and therefore already on the main actor; a `Task`-based
        // re-arm would never run during a synchronous burst and would undercount.
        let invalidations = Counter()
        func arm() {
            withObservationTracking {
                _ = store.utterances.count
            } onChange: {
                invalidations.n += 1
                MainActor.assumeIsolated { arm() }
            }
        }
        arm()

        wire.onMessage?(STTMessage(
            seq: 0, duration: 2_000, isFinal: true, text: "안녕하세요",
            confidence: 0.95, engine: .rtzr))
        try await waitUntil("translated") {
            store.utterances.first?.state == .translated
        }
        await pipeline.stop()

        // 240 tokens arriving with no delay span far less than one 33ms frame, so the
        // throttle should collapse them to a couple of writes plus the settle. The
        // bound is deliberately loose — this asserts the SHAPE (writes are decoupled
        // from token count), not an exact schedule that wall-clock jitter would make
        // flaky.
        print("[coalesce] 240 tokens -> \(invalidations.n) invalidations of `utterances`")
        XCTAssertLessThan(
            invalidations.n, 60,
            "writes are still tracking the token rate: \(invalidations.n) invalidations "
            + "for 240 tokens. Before coalescing this was ~2 per token.")
        XCTAssertEqual(store.utterances.first?.english, answer,
                       "bounding the rate must not cost the text")
    }
}
