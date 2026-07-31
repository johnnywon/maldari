# Presentation Mode — live bidirectional room translation

**Date:** 2026-07-31
**Status:** approved design, not yet planned
**Prototype:** [`docs/prototypes/presentation-mode.html`](../../prototypes/presentation-mode.html)
**Source design:** `Live Room Mode.dc.html` (claude.ai/design project `1609a5a1`)

## Summary

A full-screen, guest-facing window that renders a Korean↔English meeting as it
happens: Korean in the left column, English in the right, the current sentence
at the bottom with translation streaming in while the speaker is still talking.

Three things distinguish it from today's Subtitle Mode:

1. **Bidirectional.** Both languages are transcribed and translated, in both
   directions, at once. Today's pipeline is Korean-in / English-out only.
2. **Speculative.** Translation begins on the still-mutating STT hypothesis and
   is continuously revised, so English appears mid-sentence rather than after it.
3. **Arbitrated.** Two speech engines run on the same audio and the better
   transcript wins, per utterance.

## What exists today

`Translator/` is a SwiftPM macOS app (no xcodeproj; product is Maldari.app).
The pipeline is one-way and single-channel:

```
AudioCapturing → RTZR sommers_ko (WebSocket) → Claude Haiku KO→EN (SSE)
              → TranscriptStore → SwiftUI → SessionRecorder → CloudSyncService
```

Load-bearing facts the design has to respect:

- `Utterance` has `korean` / `english` fields; direction is baked in.
- `TranscriptStore.appendTranslation` is append-only — there is no way to
  revise text already shown.
- `RTZRStreamingService` uses `model_name=sommers_ko`. It cannot transcribe
  English.
- `AudioChunker` hardcodes 16 kHz mono Int16 in 3200-byte (100 ms) chunks, and
  `AudioCapturing`'s contract documents that rate.
- `PipelineController` already loops over an array of channels and starts every
  capture before any STT stream. `channelIDStride` (1M-apart id bands) exists
  so two streams can't collide on `Utterance.id`, but nothing has ever spawned
  a second channel.
- Translation timeouts (15 s idle / 60 s resource) are load-bearing; without
  the resource cap a wedged SSE request stalls the queue permanently.
- The `∅` filler sentinel and the `filler_override` retry protect against the
  model silently dropping real content.

## Decisions

| Question | Decision |
|---|---|
| Audio routing | **Both**, switchable: single-mic auto-detect, and dual-channel (mic + system audio) |
| English STT | **OpenAI Realtime API** (`gpt-4o-transcribe`), direct — OpenRouter cannot do streaming STT |
| OpenRouter scope | **App-wide translation provider setting**, Anthropic direct stays the default |
| Window model | **Coexists** with the transcript window; enabling it disables Subtitle Mode |
| Bidirectional scope | **Global capture mode**, not Presentation-Mode-only |
| Speculation depth | **Speculate on partials**, with prefix consensus gating what's shown as settled |
| Animation | **Treatment C — Minimal.** No per-word commit motion |

### Why OpenRouter can't cover speech

OpenRouter is a chat-completions router. It exposes no `/audio/transcriptions`
endpoint and no realtime audio WebSocket. Some models on it accept an audio
clip as message content, but that is whole-clip request/response, not the
sub-second streaming this needs. OpenRouter therefore configures **translation
only**; speech requires a direct OpenAI key.

### Why the arbiter is two-tier

An LLM judge on every utterance costs a 300–800 ms round trip and a fee per
line, which directly fights the latency goal. It is also unnecessary: the two
engines are not symmetric competitors. RTZR is a Korean specialist tuned for
business speech with keyword boosting; OpenAI is a multilingual generalist that
will emit garbage romanization for Korean-only audio and clean text for English.
Script ratio alone resolves most cases for free.

## Architecture

### Data model

`Utterance` keeps `korean` and `english`. **Korean always lands in `korean` and
English always in `english`, regardless of which was spoken.** Only
`sourceLanguage` records the direction.

Renaming to `source`/`target` would be more literally correct and would break
`SessionRecorder`'s JSONL, `transcript.md`, the cloud upload payload, and the
web viewer's parser — for nothing. The Presentation window renders Korean-left /
English-right unconditionally; direction only picks an accent color.

```swift
enum Language: String, Codable { case ko, en }

struct Utterance: Identifiable, Equatable {
    let id: Int
    let timestamp: Date
    var korean: String
    var english: String
    var sourceLanguage: Language
    var sourceState: SourceState        // .hypothesis → .draft → .arbitrated
    var target: SpeculativeText
    var state: UtteranceState           // derived, see below
}
```

`state` is retained so `TranscriptView`, `SubtitlePanel`, and `SessionRecorder`
keep working unchanged. It becomes **derived**, not independently set:
`.partial` while `sourceState == .hypothesis`, `.translating` while
`!target.settled`, `.translated` once settled with content, `.failed` on error.
Nothing should write it directly after this change.

```swift

/// A translation being progressively revised. `committedCount` is monotonic:
/// it never retreats, so text already shown as settled stays put.
struct SpeculativeText: Equatable {
    var words: [String] = []
    var committedCount: Int = 0
    var revision: Int = 0
    var settled: Bool = false

    var committed: ArraySlice<String> { words.prefix(committedCount) }
    var provisional: ArraySlice<String> { words.dropFirst(committedCount) }
    var rendered: String { words.joined(separator: " ") }
}
```

`STTMessage` gains `language: String?` and an `engine` tag.

### Prefix consensus (LA-2)

The mechanism that makes speculation safe to show. A word is **committed** once
two consecutive speculative revisions agree on it; committed words render in
the accent color and are promised not to move. Everything after the commit
frontier is the provisional tail, rendered `#6B7A85`.

```swift
enum PrefixConsensus {
    /// Returns the new (monotonic) frontier and the indices of already-committed
    /// words this revision changed.
    static func merge(previous: [String], next: [String], frontier: Int)
        -> (frontier: Int, corrected: IndexSet)
}
```

The frontier is `min(max(frontier, agreementPrefixLength), next.count)`. When a
revision disagrees with something already committed, the frontier is **held**
rather than retreating, and the changed indices are flagged for the correction
treatment. Retreating would make the whole tail flicker back to grey on every
revision, which is worse than an occasional in-place swap.

The prototype validated this against the hard case. Korean is verb-final, so on
`5천 대 기준으로는 요청하신 단가를 맞추기 어렵습니다`:

```
committed[At five thousand units]  provisional[the unit price you requested]
committed[At five thousand units]  provisional[we can't meet the unit price you asked]
committed[At five thousand units we can't meet the unit price you asked for.]
```

The frontier correctly refused to advance past "units" while the negation was
still unknown.

**Known asymmetry, accepted:** speculation buys much less on EN→KO than KO→EN.
Korean reordering means the target can barely commit until the English sentence
is nearly complete. Korean guests will see English stream in smoothly; the
operator will see Korean arrive in a chunk. This is a property of the language
pair, not something engineering fixes.

### Firing policy

Not every partial triggers a call. A speculative translation fires when **both**
hold: ≥220 ms since the last fire, and the hypothesis has grown by ≥6 characters
(Korean source) or ≥4 words (English source) since the revision that is
currently in flight. Both thresholds are tunable constants, not tuned values —
expect to adjust them against real meeting audio. The in-flight request is
cancelled first —
`AsyncThrowingStream`'s `continuation.onTermination { task.cancel() }` already
does this. Expect 4–6 calls per utterance rather than ~20.

**Out-of-order guard:** each speculative response carries its revision number.
A response whose revision is lower than the store's current revision for that
utterance is discarded. Without this, a slow revision N-1 landing after N
silently rewinds the text.

### Arbitration

Both engines run on the same audio in every bidirectional mode.

**Tier 1 — free, continuous.** While partials stream, script ratio (Hangul vs
Latin codepoint fraction) picks which engine is on home turf. No call, no
latency.

**Tier 1.5 — deterministic, on finalization.** Language agreement, engine
confidence, and normalized edit distance between the two candidates. Resolves
the large majority of lines.

**Tier 2 — LLM judge.** Fires *only* when both engines agree on the language but
disagree materially on the words. If the judge flips the source, the final
translation re-runs once. Expected on roughly 1 line in 8.

```swift
enum TranscriptArbiter {
    struct Candidate { let text: String; let language: Language; let confidence: Double? }
    enum Decision: Equatable { case pick(Language), needsJudge }
    static func decide(rtzr: Candidate?, openai: Candidate?) -> Decision
}
```

Both `PrefixConsensus.merge` and `TranscriptArbiter.decide` are pure functions
over strings — the same shape as the existing unit-tested `DisplayChoice`.

### Capture and STT

New `CaptureMode` setting:

| Mode | Channels | Engines |
|---|---|---|
| `koreanOnly` | 1 | RTZR `sommers_ko` (today, unchanged) |
| `bidirectionalSingle` | 1 source, 2 engines | RTZR + OpenAI Realtime, auto-detect |
| `bidirectionalDual` | 2 | mic → OpenAI Realtime pinned `en`; system → RTZR |

`channelSpecs(for:)` returns two specs in dual mode. This is what
`channelIDStride` and the per-channel `channel` diagnostics field were built for.

New `OpenAIRealtimeSTTService: Transcribing` — a WebSocket transcription-only
session emitting partial deltas and finals as `STTMessage`, dropping into the
existing `Transcribing` seam so `PipelineController` doesn't learn about it.

**Sample-rate wrinkle.** OpenAI Realtime expects 24 kHz PCM16; RTZR expects
16 kHz. `AudioChunker` gains a target sample rate, and `AudioCapturing`'s
documented contract is amended. In single-source bidirectional mode one capture
feeds two encoders at different rates; in dual mode each channel has its own.

*Verify against current OpenAI docs during implementation* — the exact event
names (`conversation.item.input_audio_transcription.delta` / `.completed`), the
session-configuration message, and the input audio format. Do not trust recall
here.

### Translation providers

```swift
protocol Translating: AnyObject {
    func streamTranslation(of text: String, from: Language, to: Language,
                           context: [TranslationPair], forbidSkip: Bool)
        -> AsyncThrowingStream<String, Error>
}
```

- `ClaudeTranslationService` — unchanged transport, direction-aware prompt.
- `OpenRouterTranslationService` — OpenAI-compatible SSE at
  `https://openrouter.ai/api/v1/chat/completions`; the model list comes from
  `https://openrouter.ai/api/v1/models`, cached.
- Settings picks provider + model; Anthropic direct remains the default because
  it keeps prompt caching and one less network hop.

`basePrompt` splits into two constants, `koToEnPrompt` and `enToKoPrompt`, each
mirroring the other's rules (∅ sentinel, commitment-level fidelity, glossary,
disfluency handling). **They must stay byte-stable** — the existing prompt-cache
hit depends on it, which is also why `forceTranslateSuffix` is appended rather
than woven in.

The glossary applies in both directions; EN→KO uses the reversed mapping.

### Presentation window

`PresentationWindow: NSWindow` — titled, resizable, `.fullScreenPrimary`, opening
on the display chosen by the existing `DisplayChoice` rule. Toggled from the menu
bar and Settings like Subtitle Mode. Enabling it sets `subtitleMode = false`.

Layout is a direct port of the source design: 68 px header, feed bottom-anchored
with 40/56/48 padding and 30 px row gap, history rows fading 0.30→0.58, hairline
divider, live row. Two columns, 64 px gap. Base type 34 pt × scale.

Ported rules, both pure and unit-testable:

```swift
enum PresentationLayout {
    /// 3 rows below 1.2, then 2, then 1, then none — the source design's ladder.
    static func historyDepth(forScale: Double) -> Int
    /// Shrink until the live row fits its reading area.
    static func fittedScale(requested: Double, contentHeight: CGFloat, room: CGFloat) -> Double
}
```

**Color.** Teal `#7FE3C4` when Korean was spoken, amber `#FFB86B` when English
was. Source side `#E8EEF2` once locked, `#6B7A85` while hypothesis. Caret blinks
on the source side only.

**Motion — Treatment C (chosen).**

- **No per-word commit animation.** A word crossing the frontier simply renders
  in the accent color from that frame. The moving color boundary is the signal.
- **Post-commit correction:** in-place blur swap, 240 ms. Retained even under
  the minimal treatment — a silent rewrite is more confusing than a visible one,
  and it is rare.
- **Intelligence complete:** a 1 px accent rule draws left→right beneath the
  target column over ~350 ms, then fades over ~650 ms. Fires when source
  arbitration and translation settle together.

Rationale for C over the animated options: the source design is restrained —
thin weights, muted palette, one accent — and per-word motion competes with
reading. Across a room, over an hour, the quietest treatment that still carries
the information wins.

**Controls.** Header carries the mark, a 7-bar level meter, the session clock,
font −/+, and pause. Pause maps to `pipeline.toggleListening()`, matching the
source design's own "Capture paused" status. Font −/+ writes
`presentationFontScale` (0.6–3.2), independent of transcript and subtitle scales.
In full screen the header auto-hides after 3 s idle and returns on mouse move;
source selection and start/stop stay in the menu bar, which works in full screen.

**Typography.** Ship with SF Pro / SF Mono (already `Theme`'s faces) and Apple
SD Gothic Neo for Korean. The source design specifies IBM Plex Sans / Sans KR /
Mono, which are not on macOS; bundling them (OFL, ~2 MB) remains open — see
Open items.

**Branding.** Source design reads `SORI`; this app is Maldari. Use the existing
`말` mark plus a MALDARI wordmark.

### Level meter

Chunks already pass through `PipelineController.counted()`. That wrapper computes
RMS per 100 ms chunk alongside its existing count — no new tap, no new capture
surface.

### Persistence

- `SessionRecorder.recordFinal` gains `lang`. `events.jsonl` gets an additive
  `lang` field; existing readers are unaffected.
- **Only settled text is written.** Speculative revisions never reach disk.
  Recording fires on arbitration (source) and settle (translation). If a session
  ends mid-flight, whatever is committed is flushed.
- `exportMarkdown` marks direction per row.
- Cloud upload payload shape is unchanged — the Worker and web viewer need no
  deploy.

## Module inventory

**New**

| File | Responsibility |
|---|---|
| `Support/Language.swift` | `Language`, script-ratio detection |
| `Support/PrefixConsensus.swift` | LA-2 merge (pure) |
| `Support/TranscriptArbiter.swift` | Two-tier arbitration rule (pure) |
| `Support/PresentationLayout.swift` | History depth + fit rule (pure) |
| `Support/AudioLevelMeter.swift` | RMS per chunk |
| `Models/SpeculativeText.swift` | Committed/provisional word state |
| `Services/OpenAIRealtimeSTTService.swift` | Realtime WebSocket STT |
| `Services/OpenRouterTranslationService.swift` | OpenRouter SSE translation |
| `Services/TranslationJudge.swift` | Tier-2 LLM arbiter |
| `Views/PresentationWindow.swift` | Window lifecycle, display, full screen |
| `Views/PresentationView.swift` | The rendered design |

**Modified:** `AppSettings`, `PipelineController`, `TranscriptStore`,
`Models/Utterance`, `Models/STTMessage`, `Services/TranslationService`,
`Services/AudioCapturing`, `MicrophoneCaptureService`,
`SystemAudioCaptureService`, `StatusItemController`, `Views/PreferencesView`,
`Store/SessionRecorder`, `TranslatorApp`, `Views/TranscriptView`.

### Settings surface

- **General** — Presentation Mode toggle, display, font scale.
- **Transcription** — capture mode picker.
- **Translation** (new tab) — provider, OpenRouter model, glossary moves here.
- **API Keys** — adds OpenAI and OpenRouter, keychain-backed, each with Test
  Connection alongside the existing RTZR and Anthropic rows.

## Testing

Following the established pattern: extract the rule, test the rule, don't test
through AppKit.

- `PrefixConsensus.merge` — advance, hold-on-correction, monotonicity,
  empty/identical/truncating revisions.
- `TranscriptArbiter.decide` — language split, confidence gap, edit-distance
  threshold, the `needsJudge` boundary.
- `Language` script ratio — pure Hangul, pure Latin, mixed, numerals, empty.
- `PresentationLayout` — the 3/2/1/0 ladder at boundary scales; fit convergence.
- Direction-aware prompt selection.
- **Dual-channel pipeline test** asserting `channelIDStride` id bands don't
  collide. That scaffolding has never run with two channels; this is the first
  thing that will exercise it.
- Out-of-order speculative response is discarded.

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift test`.

## Implementation phases

Each phase is independently shippable and testable.

1. **Bidirectional foundation** — `Language`, direction-aware `Translating`,
   `Utterance.sourceLanguage`, derived `state`, split prompts. Ships behind the
   existing UI, which starts showing direction accents on transcript rows.
2. **OpenAI Realtime STT + capture modes** — the new service, sample-rate
   parameterization, single and dual bidirectional modes. **Includes the OpenAI
   key row in the API Keys tab and the capture-mode picker** — phase 2 is
   unusable without them.
3. **Arbitration** — tiers 1 and 1.5 first; the LLM judge last.
4. **Speculative translation** — `SpeculativeText`, the revision-based store
   API, firing policy, out-of-order guard.
5. **Presentation window** — layout, motion, controls, full screen.
6. **OpenRouter provider** — service, model picker, Translation tab, OpenRouter
   key row.
7. **Recording / export / cloud** direction fields.

Phases 1–4 change the pipeline for the whole app; phase 5 is the visible payoff.

## Cost

| | Today | Presentation Mode |
|---|---|---|
| STT | 1 stream | 2 streams (one billed per audio-minute) |
| Translation | 1 call/utterance | ~5 short prompt-cached calls/utterance |
| Judge | — | ~1 line in 8 |
| **Per hour** | **~$0.40** | **~$1.50** |

## Risks

- **Two-engine reconciliation is the hardest part.** Both engines finalize on
  their own timelines; matching their utterances to each other before arbitrating
  is fiddlier than the arbitration itself. If this proves unstable, the fallback
  is dual-channel-only bidirectional (direction known by channel, no matching
  required) and dropping single-mic auto-detect.
- **Single-mic auto-detect will mis-fire on short utterances** — a clipped 네 can
  read as English. Mitigated by a minimum-duration gate before a direction flip
  and falling back to the previous utterance's language.
- **`TranscriptStore` becomes revision-based**, which is a real change to the
  contract every view depends on. The uncommitted `indexByID` optimization
  currently in the working tree should land before this work starts.
- **OpenRouter loses Anthropic prompt caching** and adds a hop. Default stays
  Anthropic direct.

## Open items

- **Bundle IBM Plex?** (~2 MB, OFL) for the source design's exact voice, versus
  SF Pro which is already the app's face. Decide after seeing Korean rendered at
  presentation sizes on a real external display.
- Judge model choice for tier 2 — likely the same Haiku, but worth measuring
  against a cheaper option once there is real disagreement data to test on.
