import XCTest
@testable import Translator

/// "Memory seemed loaded" after a real meeting.
///
/// `PerfBaselineTests` showed the transcript itself is small — about 2 KB per
/// utterance, under a megabyte for an hour — so if memory climbs, it climbs somewhere
/// other than the store. This drives a whole simulated meeting through the real
/// `PipelineController` with only the network faked, so everything that retains state
/// per utterance is in scope: the speculation bookkeeping, the recorder, the
/// arbitration coordinator, the translation queue, and every Task any of them spawn.
///
/// Hermetic and fast — 500 utterances in a couple of seconds — so it can run in the
/// normal suite and catch a retain cycle the day it is introduced, rather than after
/// the next hour-long meeting.
@MainActor
final class MemorySoakTests: XCTestCase {

    /// A 60-minute meeting at ~7s per utterance.
    private static let meetingUtterances = 500

    private final class EchoTranslator: Translating, @unchecked Sendable {
        func streamTranslation(
            of text: String, from source: Language, to target: Language,
            context: [TranslationPair], forbidSkip: Bool
        ) -> AsyncThrowingStream<String, Error> {
            // A realistic-length answer, streamed in several tokens.
            let answer = "Tooling costs are billed separately and the unit price varies "
                + "with the initial order quantity"
            return AsyncThrowingStream { continuation in
                var sent = ""
                for word in answer.split(separator: " ") {
                    sent += (sent.isEmpty ? "" : " ") + word
                    continuation.yield(sent.isEmpty ? String(word) : " " + String(word))
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

    func test_soak_aFullMeetingDoesNotGrowWithoutBound() async throws {
        var wires: [String: Wire] = [:]
        let pipeline = PipelineController(
            translator: EchoTranslator(), judge: NoopTranscriptJudge())
        pipeline.credentialsCheck = { true }
        pipeline.makeCapture = { _, _ in SilentCapture() }
        pipeline.makeTranscriber = { _, _, channel in
            let w = Wire(); wires[channel] = w; return w
        }

        let settings = AppSettings.shared
        let previousMode = settings.captureModeRaw
        let previousSpeculative = settings.speculativeTranslation
        settings.captureModeRaw = CaptureMode.koreanOnly.rawValue
        // Speculation ON: it is the feature that allocates the most per utterance
        // (a Task and a bookkeeping entry per revision), so leaving it off would
        // exclude the most likely source of growth.
        settings.speculativeTranslation = true
        defer {
            settings.captureModeRaw = previousMode
            settings.speculativeTranslation = previousSpeculative
        }

        await pipeline.start()
        let wire = try XCTUnwrap(wires["main"])

        let korean = "금형 비용은 별도로 청구되며 초기 발주 수량에 따라 단가가 달라집니다"
        var samples: [(Int, Double)] = []

        // Settle the allocator before the first sample, so one-off warmup is not
        // attributed to the meeting.
        for seq in 0..<20 {
            wire.onMessage?(STTMessage(
                seq: seq, duration: 2_000, isFinal: true, text: korean,
                confidence: 0.95, engine: .rtzr))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let baseline = footprintMB()

        for seq in 20..<Self.meetingUtterances {
            // A hypothesis then a final, which is what a real utterance looks like and
            // what drives the speculation path.
            wire.onMessage?(STTMessage(
                seq: seq, isFinal: false, text: String(korean.prefix(12)), engine: .rtzr))
            wire.onMessage?(STTMessage(
                seq: seq, duration: 2_000, isFinal: true, text: korean,
                confidence: 0.95, engine: .rtzr))
            if seq % 100 == 0 {
                try await Task.sleep(nanoseconds: 200_000_000)
                samples.append((seq, footprintMB()))
            }
        }

        // Let every in-flight translation drain before the final reading, so what is
        // measured is retained state and not work still in progress.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await pipeline.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        let after = footprintMB()

        let trace = samples.map { String(format: "%d:%.1f", $0.0, $0.1) }.joined(separator: " ")
        let grew = after - baseline
        print(String(format:
            "[soak] footprint %.1f MB -> %.1f MB (+%.1f MB) over %d utterances "
            + "= %.1f KB each | trace %@",
            baseline, after, grew, Self.meetingUtterances - 20,
            grew * 1024 / Double(Self.meetingUtterances - 20), trace))

        XCTAssertEqual(pipeline.store.utterances.count, Self.meetingUtterances)

        // Every hypothesis must have released its speculation bookkeeping when it
        // finalized. A single leaked entry per utterance is how this kind of growth
        // usually starts, and it holds a Task alive with it.
        XCTAssertTrue(
            pipeline.store.partials.isEmpty,
            "hypotheses outlived their finals: \(pipeline.store.partials.count) left")

        // 25 MB over an hour-long meeting. Generous next to the ~1 MB the transcript
        // itself needs, and far under the point at which a MacBook Air starts
        // swapping — but tight enough that a per-utterance leak trips it.
        XCTAssertLessThan(
            grew, 25,
            "memory grew \(String(format: "%.1f", grew)) MB over one meeting — "
            + "something retains state per utterance")
    }
}
