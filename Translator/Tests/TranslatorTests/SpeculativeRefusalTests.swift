import XCTest
@testable import Translator

/// A speculative pass that comes back a refusal must not leave that refusal on the
/// guest-facing screen.
///
/// The finalized translation path handles this: it calls `store.clearTranslation` when
/// the completed response is filler. The speculative path only `return`s — so whatever
/// was streamed into the live hypothesis row stays rendered until the sentence finalizes,
/// which for a trailing-off speaker may be never.
///
/// This was always partly broken: `isRefusal` requires both a meta marker and an
/// inability marker, so the streaming guard could not block "I'm unable to" until the
/// word "input" arrived, and by then the earlier tokens were already on screen. Moving
/// the streaming guard to `isSentinel` for performance made the whole refusal visible
/// rather than a fragment of it, which is what forced the real fix.
///
/// The room reads this window. A model apologising to it is the one output that is
/// unrecoverable.
@MainActor
final class SpeculativeRefusalTests: XCTestCase {

    /// Returns a refusal, word by word, **at a provider's pace**.
    ///
    /// The 40 ms gap is load-bearing, not decoration. Translation writes are coalesced
    /// to 1/30 s, so a fixture that yields every token synchronously collapses to a
    /// single write and the row only ever shows the first word — which is not a refusal,
    /// so the test passes whether or not the bug is fixed. The first version of this
    /// test did exactly that and survived having its own fix deleted. Real tokens arrive
    /// milliseconds apart and clear the throttle, so the fixture must too.
    private final class RefusingTranslator: Translating, @unchecked Sendable {
        static let refusal =
            "I'm unable to parse that input with confidence. Could you please repeat?"

        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

        func streamTranslation(
            of text: String, from source: Language, to target: Language,
            context: [TranslationPair], forbidSkip: Bool
        ) -> AsyncThrowingStream<String, Error> {
            lock.lock(); _calls += 1; lock.unlock()
            return AsyncThrowingStream { continuation in
                Task {
                    for (i, word) in Self.refusal.split(separator: " ").enumerated() {
                        continuation.yield(i == 0 ? String(word) : " " + String(word))
                        try? await Task.sleep(nanoseconds: 40_000_000)
                    }
                    continuation.finish()
                }
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

    private func waitUntil(
        _ label: String, timeout: TimeInterval = 4, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    func test_aRefusedSpeculativePassLeavesNothingOnScreen() async throws {
        var wires: [String: Wire] = [:]
        let translator = RefusingTranslator()
        let pipeline = PipelineController(
            translator: translator, judge: NoopTranscriptJudge())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, _ in SilentCapture() }
        pipeline.makeTranscriber = { _, _, channel in
            let w = Wire(); wires[channel] = w; return w
        }

        let settings = AppSettings.shared
        let previousMode = settings.captureModeRaw
        let previousSpeculative = settings.speculativeTranslation
        settings.captureModeRaw = CaptureMode.koreanOnly.rawValue
        settings.speculativeTranslation = true
        defer {
            settings.captureModeRaw = previousMode
            settings.speculativeTranslation = previousSpeculative
        }

        await pipeline.start()
        let wire = try XCTUnwrap(wires["main"])

        // A hypothesis long enough to trip `speculativeMinLength`.
        wire.onMessage?(STTMessage(
            seq: 0, isFinal: false,
            text: "금형 비용은 별도로 청구되며 초기 발주 수량에 따라 단가가 달라집니다",
            engine: .rtzr))

        // Wait for the refusal to be fully on screen — the state the fix must undo.
        let streamed = await waitUntil("refusal visible mid-stream") {
            pipeline.store.currentPartial?.targetText.contains("unable to") == true
        }
        XCTAssertTrue(
            streamed,
            "the refusal never reached the row, so this test cannot observe whether it "
            + "is taken back off again")
        // Then let the pass complete, which is when the discard runs.
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let partial = try XCTUnwrap(pipeline.store.currentPartial)
        await pipeline.stop()
        print("[refusal] translator calls=\(translator.calls) "
              + "hasStarted=\(partial.target.hasStarted) "
              + "targetText=\"\(partial.targetText)\"")

        // Without this the test is vacuous: if no speculative pass ever ran there is
        // no refusal to leave on screen, and every assertion below passes for the
        // wrong reason. That is exactly how the first version of this test survived
        // having its own fix removed.
        XCTAssertGreaterThan(translator.calls, 0, "no speculative pass ever fired")
        XCTAssertTrue(partial.target.hasStarted, "nothing was ever streamed into the row")

        XCTAssertFalse(
            partial.targetText.contains("unable to"),
            "the refusal is on the guest-facing screen: \"\(partial.targetText)\"")
        XCTAssertFalse(
            TranslationFilter.isRefusal(partial.targetText),
            "the live row renders a refusal: \"\(partial.targetText)\"")
    }

    /// The revert must not cost words that already earned consensus. A refused pass is
    /// evidence about nothing; it is not evidence against what two earlier revisions
    /// already agreed on.
    func test_revertingARefusalKeepsCommittedWords() {
        var buffer = SpeculativeText()
        // Two agreeing revisions commit a prefix.
        XCTAssertTrue(buffer.apply(revision: 0, text: "Tooling costs are billed"))
        XCTAssertTrue(buffer.apply(revision: 1, text: "Tooling costs are billed separately"))
        let committedBefore = buffer.effectiveCommittedCount
        XCTAssertGreaterThan(committedBefore, 0, "the fixture must commit something")
        let renderedBefore = buffer.rendered

        // A refusal streams in over the top, then is reverted.
        buffer.applyStreaming(text: RefusingTranslator.refusal)
        buffer.revertToLastRevision()

        XCTAssertEqual(buffer.rendered, renderedBefore,
                       "the revert must restore the last completed revision exactly")
        XCTAssertEqual(buffer.effectiveCommittedCount, committedBefore,
                       "the commit frontier must survive a refused pass")
        XCTAssertFalse(buffer.rendered.contains("unable"))
    }
}
