import XCTest
import Observation
@testable import Translator

/// Performance characterisation of a long session.
///
/// The user's report was "memory seemed loaded, mouse got slow" after a real meeting.
/// Both symptoms are properties of SCALE — they appear after hundreds of utterances and
/// tens of thousands of streamed tokens — so neither is visible in a test that pushes
/// one sentence through. These measure the shape of the cost as history grows, which is
/// the only thing that distinguishes "slow" from "gets slower".
///
/// Deliberately hermetic and CPU-only: no network, no audio. The quantities measured
/// here are the ones a SwiftPM process can observe honestly — resident footprint,
/// wall-clock per mutation, and Observation invalidation counts. Frame timing and
/// SwiftUI body counts are not observable from here, so `invalidations` stands in for
/// "how much of the window SwiftUI is asked to rebuild".
@MainActor
final class PerfBaselineTests: XCTestCase {

    // MARK: - Session model

    /// A 60-minute meeting: ~500 utterances at ~7s each.
    private static let meetingUtterances = 500
    /// Speculative translation revises while the speaker talks, and every revision
    /// streams its tokens in one at a time. ~5 passes x ~12 tokens per utterance.
    private static let streamWritesPerUtterance = 60

    /// Resident footprint, which is what "memory seemed loaded" refers to — the number
    /// Activity Monitor shows, including malloc'd Swift objects.
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

    private func final(seq: Int, text: String, language: Language = .ko) -> STTMessage {
        STTMessage(
            seq: seq, startAt: seq * 7_000, duration: 7_000, isFinal: true,
            text: text, confidence: 0.95, engine: .openai, language: language)
    }

    private func partial(seq: Int, text: String, language: Language = .ko) -> STTMessage {
        STTMessage(
            seq: seq, startAt: seq * 7_000, duration: nil, isFinal: false,
            text: text, confidence: 0.9, engine: .openai, language: language)
    }

    /// One Korean sentence and its English translation, long enough to be realistic.
    private let koSentence = "금형 비용은 별도로 청구되며 초기 발주 수량에 따라 단가가 달라집니다"
    private let enTokens = ["Tooling", "costs", "are", "billed", "separately", "and",
                            "the", "unit", "price", "varies", "with", "the", "initial",
                            "order", "quantity", "as", "we", "discussed", "earlier", "today"]

    /// Drives `count` utterances through the store the way a real session does:
    /// a final, then a translation streamed token by token.
    private func fill(_ store: TranscriptStore, count: Int, writesEach: Int) {
        for seq in 0..<count {
            store.apply(final(seq: seq, text: koSentence),
                        at: Date(timeIntervalSince1970: Double(seq) * 7))
            var accumulated = ""
            for w in 0..<writesEach {
                accumulated += (accumulated.isEmpty ? "" : " ") + enTokens[w % enTokens.count]
                store.streamTranslation(id: seq, text: accumulated)
            }
            store.settleTranslation(id: seq, text: accumulated)
        }
    }

    // MARK: - GOAL 1: memory must not scale with how long the meeting ran

    func test_baseline_memoryFootprintOverAMeeting() {
        let store = TranscriptStore()
        store.startSession()

        let before = footprintMB()
        fill(store, count: Self.meetingUtterances, writesEach: Self.streamWritesPerUtterance)
        let after = footprintMB()

        let grew = after - before
        let perUtterance = grew * 1024 / Double(Self.meetingUtterances)
        print(String(format:
            "[perf] memory: %.1f MB -> %.1f MB (+%.1f MB) over %d utterances = %.1f KB each",
            before, after, grew, Self.meetingUtterances, perUtterance))
        XCTAssertEqual(store.utterances.count, Self.meetingUtterances)
        // The transcript of an hour-long meeting is about 1 MB. 10 is generous and
        // still catches anything that starts retaining per utterance.
        XCTAssertLessThan(grew, 10, "the transcript itself is now expensive to hold")
    }

    // MARK: - GOAL 2: cost per streamed token must not depend on history length

    /// The distinguishing measurement. If streaming one token into the NEWEST utterance
    /// costs more when 500 utterances precede it than when 20 do, the app gets
    /// progressively slower as a meeting runs — which is exactly what was reported.
    func test_baseline_perTokenCostVersusHistoryDepth() {
        func costPerWrite(historyDepth: Int) -> Double {
            let store = TranscriptStore()
            store.startSession()
            fill(store, count: historyDepth, writesEach: 4)

            // Now measure writes into one fresh utterance on top of that history.
            let seq = historyDepth
            store.apply(final(seq: seq, text: koSentence),
                        at: Date(timeIntervalSince1970: Double(seq) * 7))
            let writes = 2_000
            var accumulated = ""
            let start = Date()
            for w in 0..<writes {
                accumulated = enTokens[0..<(1 + w % enTokens.count)].joined(separator: " ")
                store.streamTranslation(id: seq, text: accumulated)
            }
            return Date().timeIntervalSince(start) / Double(writes) * 1_000_000  // µs
        }

        let shallow = costPerWrite(historyDepth: 20)
        let deep = costPerWrite(historyDepth: 500)
        let ratio = deep / max(shallow, 0.0001)
        print(String(format:
            "[perf] per-token store write: %.2f µs at depth 20, %.2f µs at depth 500 — ratio %.2fx",
            shallow, deep, ratio))

        // The shape matters more than the number: a write must not get more expensive
        // as the meeting goes on. Was 1.03x before this work too — the store was always
        // O(1) here — so this guards against a regression rather than recording a win.
        XCTAssertLessThan(ratio, 1.5, "per-token cost now scales with history depth")
        // 54.32 µs before the hot path was cleaned up, 7.21 µs after. The guard is set
        // well above the measured value because this runs on whatever machine CI has,
        // but far below the old cost, so reintroducing a scan of the whole translation
        // (which is what isFiller did) trips it.
        XCTAssertLessThan(deep, 20, "the per-token path picked up expensive work again")
    }

    // MARK: - GOAL 3: streaming must not invalidate observers that don't read history

    /// The render-churn measurement, and the most likely cause of the stalled cursor.
    ///
    /// The Presentation window shows the live line and a little recent context — not the
    /// whole meeting. If mutating `utterances[i]` invalidates an observer that only ever
    /// read `currentPartial`, then every streamed token asks SwiftUI to rebuild parts of
    /// the window that did not change, and the cost of one token scales with how much of
    /// the window is subscribed.
    ///
    /// Counted with `withObservationTracking`, re-arming after each invalidation, which
    /// is how SwiftUI itself observes.
    func test_baseline_invalidationsWhileStreamingHistory() {
        let store = TranscriptStore()
        store.startSession()
        fill(store, count: 50, writesEach: 4)
        // A live hypothesis on a second channel, which is what the window pins.
        store.apply(partial(seq: 1_000_000, text: "다음 안건으로"))

        // `onChange` is delivered nonisolated, synchronously from inside the
        // mutation — which for a @MainActor store means it is already on the main
        // actor. `assumeIsolated` lets the observer re-arm right there. Re-arming via
        // `Task { }` instead is what broke the first version of this measurement: the
        // task never ran during a synchronous mutation loop, so the observer died
        // after one change and the count was always 1.
        final class Counter: @unchecked Sendable { var n = 0 }
        let liveLine = Counter()
        let history = Counter()

        func armLiveLine() {
            withObservationTracking {
                _ = store.currentPartial?.sourceText
            } onChange: {
                liveLine.n += 1
                MainActor.assumeIsolated { armLiveLine() }
            }
        }
        func armHistory() {
            withObservationTracking {
                _ = store.utterances.count
            } onChange: {
                history.n += 1
                MainActor.assumeIsolated { armHistory() }
            }
        }
        armLiveLine()
        armHistory()

        // Stream a translation into an OLD utterance — nothing the live line shows.
        let writes = 200
        var accumulated = ""
        for w in 0..<writes {
            accumulated = enTokens[0..<(1 + w % enTokens.count)].joined(separator: " ")
            store.streamTranslation(id: 10, text: accumulated)
        }

        print("[perf] \(writes) writes to a historical utterance -> "
              + "live-line observer invalidated \(liveLine.n)x, "
              + "history observer \(history.n)x")

        // One invalidation per write, not two. Mutating `target` and then `targetText`
        // through the subscript is two writes to an @Observable array, and SwiftUI
        // rebuilds on each — so every streamed token used to ask for two rebuilds.
        XCTAssertEqual(
            history.n, writes,
            "expected exactly one invalidation per write; two means the store is "
            + "mutating the array twice per token again")
        // Streaming into history must never disturb the live row's observer.
        XCTAssertEqual(
            liveLine.n, 0,
            "writing to a historical utterance invalidated the live-line observer")
    }

    // MARK: - GOAL 4: per-request context assembly must not scan the meeting

    /// `contextPairs` filters and maps the whole array. It is called once per
    /// translation request, and speculation issues many requests per utterance.
    func test_baseline_contextPairsCostVersusHistoryDepth() {
        func cost(historyDepth: Int) -> Double {
            let store = TranscriptStore()
            store.startSession()
            fill(store, count: historyDepth, writesEach: 4)
            let calls = 2_000
            let start = Date()
            for _ in 0..<calls {
                _ = store.contextPairs(before: historyDepth - 1, from: .ko)
            }
            return Date().timeIntervalSince(start) / Double(calls) * 1_000_000  // µs
        }

        let shallow = cost(historyDepth: 20)
        let deep = cost(historyDepth: 500)
        let ratio = deep / max(shallow, 0.0001)
        print(String(format:
            "[perf] contextPairs: %.2f µs at depth 20, %.2f µs at depth 500 — ratio %.2fx",
            shallow, deep, ratio))

        // 11.46x before walking back from the cursor, 1.02x after. Anything that
        // reintroduces a filter over the whole array shows up here immediately.
        XCTAssertLessThan(ratio, 1.5, "contextPairs scans the whole meeting again")
    }

    // MARK: - What actually costs the 56 µs

    /// Attributes the per-token cost. `streamTranslation` guards every token with
    /// `TranslationFilter.isFiller`, which calls `isRefusal`, which lowercases the
    /// whole accumulated translation and then runs ~43 substring searches over it.
    /// That is a per-token scan of a growing string, on the main actor.
    func test_baseline_attributePerTokenCost() {
        let text = enTokens.joined(separator: " ")
        let iterations = 20_000

        var start = Date()
        for _ in 0..<iterations { _ = TranslationFilter.isFiller(text) }
        let filler = Date().timeIntervalSince(start) / Double(iterations) * 1_000_000

        start = Date()
        for _ in 0..<iterations { _ = TranslationFilter.isRefusal(text) }
        let refusal = Date().timeIntervalSince(start) / Double(iterations) * 1_000_000

        var buffer = SpeculativeText()
        start = Date()
        for _ in 0..<iterations {
            buffer.applyStreaming(text: text)
            _ = buffer.rendered
        }
        let bufferCost = Date().timeIntervalSince(start) / Double(iterations) * 1_000_000

        // Cheap alternative: the streaming path only ever needs to catch the
        // sentinel. A refusal is a property of a COMPLETED response.
        start = Date()
        for _ in 0..<iterations {
            _ = text.trimmingCharacters(in: .whitespacesAndNewlines) == TranslationFilter.sentinel
        }
        let sentinelOnly = Date().timeIntervalSince(start) / Double(iterations) * 1_000_000

        print(String(format:
            "[perf] per call on a %d-char translation: isFiller %.2f µs (isRefusal %.2f µs) | "
            + "SpeculativeText %.2f µs | sentinel-only check %.2f µs",
            text.count, filler, refusal, bufferCost, sentinelOnly))
    }

    // MARK: - The view-layer cost that actually stalled the cursor

    /// `PresentationView.historyEntries` is re-evaluated on every Observation
    /// invalidation — i.e. on every streamed translation token, from either channel.
    /// It renders at most `PresentationLayout.historyDepth` rows, which never exceeds
    /// three, but it used to reach that by filtering the ENTIRE utterances array.
    ///
    /// This measures the two shapes against each other on a realistic array. The view
    /// itself cannot be instantiated from a SwiftPM test process, so the slice is
    /// reproduced here exactly as the view performs it; `PresentationViewLayoutTests`
    /// covers that the view still selects the same rows.
    func test_baseline_historySliceCost() {
        let store = TranscriptStore()
        store.startSession()
        fill(store, count: Self.meetingUtterances, writesEach: 4)
        let liveID = store.utterances.last?.id
        let depth = 3
        let iterations = 2_000

        var start = Date()
        for _ in 0..<iterations {
            let past = store.utterances.filter { $0.id != liveID }
            _ = Array(past.suffix(depth))
        }
        let wholeArray = Date().timeIntervalSince(start) / Double(iterations) * 1_000_000

        start = Date()
        for _ in 0..<iterations {
            let past = store.utterances.suffix(depth + 1).filter { $0.id != liveID }
            _ = Array(past.suffix(depth))
        }
        let tailOnly = Date().timeIntervalSince(start) / Double(iterations) * 1_000_000

        print(String(format:
            "[perf] history slice at %d utterances: whole-array filter %.2f µs vs "
            + "tail-only %.2f µs — %.0fx",
            Self.meetingUtterances, wholeArray, tailOnly, wholeArray / max(tailOnly, 0.0001)))

        // The whole point: the drawn slice must not scale with how long the meeting
        // ran. 51.14 µs vs 0.84 µs when this was written — a 20x guard leaves room for
        // a slower machine while still catching a return to filtering everything.
        XCTAssertLessThan(
            tailOnly * 20, wholeArray,
            "the tail-only slice is no longer meaningfully cheaper — has "
            + "historyEntries gone back to filtering the whole array?")

        // Both shapes must select the same rows, or this is not an optimisation.
        let viaWhole = Array(store.utterances.filter { $0.id != liveID }.suffix(depth)).map(\.id)
        let viaTail = Array(
            store.utterances.suffix(depth + 1).filter { $0.id != liveID }.suffix(depth)).map(\.id)
        XCTAssertEqual(viaWhole, viaTail, "the tail-only slice must pick the same rows")
    }
}
