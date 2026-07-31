# Maldari (말다리) — Korean↔English live meeting translator (macOS)

SwiftPM app in `Translator/` (no xcodeproj; target keeps the Translator name,
the product/bundle is Maldari.app). Pipeline:
audio capture (mic / system / single-app) → streaming STT (WebSocket) →
[arbitration, bidirectional modes only] → translation (SSE) → TranscriptStore →
SwiftUI transcript panel / Presentation window → SessionRecorder (disk) →
CloudSyncService (your Worker).

Three capture modes (`CaptureMode`, Settings → Transcription):
`koreanOnly` is the original one-way path (RTZR only). `bidirectionalSingle`
runs both engines on one audio source and arbitrates. `bidirectionalDual` runs
RTZR on the call's audio (Korean guests) and OpenAI on the mic (English
operator), so direction is known rather than detected. Bidirectional modes need
a direct OpenAI key — OpenRouter has no realtime audio endpoint.

`web/` is the Cloudflare Worker behind https://maldari.johnnywon.com —
landing page, login-gated session viewer (R2), and the app's upload API.
Deploy: `cd web && npx wrangler deploy` (secrets in
~/Developer/build-pref/secrets.env as MALDARI_*).

## Build / test / run

```bash
cd Translator
DEVELOPER_DIR=/Applications/Xcode.app swift build
DEVELOPER_DIR=/Applications/Xcode.app swift test   # CLT alone lacks XCTest
bash Scripts/make-app.sh Release                    # → build/Maldari.app
```

After re-signing the app bundle, macOS may re-prompt for Microphone /
System Audio Recording permissions.

## Bug-killing mode (diagnostics)

The app writes structured JSONL diagnostics for every session:

- **Diagnostic logs**: `~/Library/Logs/Maldari/maldari-<timestamp>.jsonl`
  — one file per app launch. Categories: `app`, `session`, `ws`, `stt`,
  `translate`, `queue`. Includes per-translation latency (`wait_ms`,
  `ttft_ms`, `total_ms`), WebSocket drops with close codes, reconnect
  attempts, HTTP error bodies, and a 30s `heartbeat` event (queue depth,
  audio chunk counts, STT silence). `stt_stalled` / `gave_up` events mark
  the moment a session died.
- **Session recordings**: `~/Library/Application Support/Maldari/sessions/session-<timestamp>/`
  — `events.jsonl` (every finalized Korean line + completed translation,
  written live) and `transcript.md` (rolling snapshot, debounced 2s). A
  crash or restart loses nothing; recover from the newest session folder.

To investigate a reported bug: read the newest log file, find `level:error`
events and `heartbeat` lines around the reported time, and correlate with
the session recording.

## Known behaviors — bidirectional / speculative

- **`Utterance.korean` and `.english` are language-named, not role-named.**
  Korean always lands in `korean` and English always in `english`, whichever was
  spoken; only `sourceLanguage` records the direction. This is why
  `SessionRecorder`'s JSONL, `transcript.md`, the cloud payload, and the web
  viewer all survived the bidirectional change untouched. Use
  `sourceText` / `targetText` to address them by role.
- **`Utterance.state` is derived, never written.** With speculative translation
  there is no single moment that is "translating". It is computed from
  `sourceState` and `target.settled` / `target.hasStarted`.
- **`SpeculativeText.committedCount` may exceed `words.count`.** Deliberate: the
  final pass streams in from empty while the frontier still refers to words
  committed during the hypothesis. Clamping the stored value ratcheted it down to
  the partial stream's length and — since that clamp only decreases — collapsed it
  to zero permanently, destroying every carried commitment. Read through
  `effectiveCommittedCount` / `committed` / `provisional`.
- **`beginTranslationPass` vs `restartTranslation`.** The first final pass keeps
  the commit frontier (`beginTranslationPass`); only the forced retry after a
  wrong ∅ discards it (`restartTranslation`), because that pass re-translates
  from scratch. Calling restart on the first pass reintroduces the grey flicker
  the whole consensus mechanism exists to prevent.
- **`SpeculativeText.hasStarted` is a stored flag, not `revision >= 0`.**
  `restart()`, `applyStreaming()` and `clear()` all mean a pass has begun but none
  completes a revision, so deriving it made streaming rows read `.finalized` and
  left cleared filler rows stuck there forever.
- **Speculative passes apply atomically, streaming does not.** Tokens go through
  `applyStreaming` (no consensus); a completed pass goes through
  `apply(revision:)` (consensus). Running consensus per token would commit words
  on the strength of nothing.
- **OpenAI is the segmenter of record in `bidirectionalSingle`; RTZR challenges
  finals only, and partials come from the segmenter alone.** The engines segment
  independently (RTZR epd 0.5s vs OpenAI server VAD), so forwarding both
  hypotheses would make the single live line flip-flop between two engines
  mid-word. RTZR's partials are marginally faster; that is the price of a stable
  line.
- **The RTZR challenger is NOT language-pinned.** Pinning stamped `.ko` onto its
  transcript of English speech, hiding the very signal
  (`TranscriptArbiter` rule 3) that the two-engine setup exists to produce.
  Pinning applies only where a channel genuinely is one language: dual mode and
  `koreanOnly`.
- **Sample rate is per capture instance.** RTZR wants 16 kHz, the OpenAI Realtime
  API wants 24 kHz. `bidirectionalSingle` therefore runs *two* captures of the
  same source; that works because `SystemAudioCaptureService` gives each tap a
  fresh `CATapDescription.uuid` and aggregate-device UID.
- **The OpenAI Realtime transcription API changed at GA.** It is
  `session.update` with `session.type = "transcription"` and
  `session.audio.input.format = {type: "audio/pcm", rate: 24000}` — not the beta's
  `transcription_session.update` / `input_audio_format: "pcm16"` — and the
  `OpenAI-Beta` header is gone. Verify against docs before editing
  `OpenAIRealtimeSTTService`; training data is stale here.
- **Presentation Mode is driven entirely by `AppSettings.presentationMode`,**
  polled every 0.25s in `AppDelegate.applySettings`. That is why
  `PresentationWindow.onClose` exists: without it, the close button's window
  would reappear a quarter second later. Turning Presentation Mode on forces
  Subtitle Mode off.
- The two translation prompts (`TranslationPrompt.koToEn` / `.enToKo`) must stay
  byte-stable and the glossary/force-retry text must stay appended, or Anthropic
  prompt caching stops hitting and a meeting's cost jumps.

### Traps that bit during the build (all found by review, not by tests)

- **`SpeculativeText.revisionWords` is the consensus baseline; `words` is the
  render buffer.** The pipeline streams tokens into `words` and *then* calls
  `apply(revision:)` with the same accumulated string, so merging against `words`
  compares a pass with itself: agreement is total, every pass commits 100% of its
  own guess, and `correctedIndices` is always empty. Unit tests that call `apply`
  directly cannot see this — only tests that interleave `applyStreaming` first can.
  See `SpeculativeTextTests`' "production interleaving" section.
- **`applyStreaming` swaps whole arrays; never splice by word index.** Word N of a
  new translation does not correspond to word N of the old one — a revision that
  inserts or drops a word ahead of the frontier shifts everything after it, and a
  splice then drops or duplicates words on screen.
- **Any `partials` mutation must be scoped to the message's channel band.** Both
  the empty-final and non-empty-final paths. `removeAll()` unscoped destroys the
  other speaker's live hypothesis and its committed translation, and engines emit
  blank finals routinely on silence.
- **A mid-hypothesis language flip invalidates the frontier AND the carry-over.**
  A Korean line opening with a numeral or romanized name detects as English for its
  first deltas, so the target accumulated is in the wrong language.
- **`isListening` is cleared at the TOP of `stop()`,** so every Start control flips
  its label the moment teardown begins. Every lifecycle operation that suspends
  must re-check the `lifecycle` token before touching session state — including
  after `translationQueue.drain()`, which is the suspension that actually lasts.
  `start()` waits out an in-flight teardown via `isStopping` rather than racing it.
- **`stop()` snapshots `channels` before its phases.** Re-reading `self.channels`
  between them lets a concurrent `start()`'s new channels be dismantled while under
  construction.
- **`credentialsCheck` must follow `translationProvider`.** Demanding Anthropic
  unconditionally made an OpenRouter-only setup unable to start at all.
- **A challenger channel dying must not end the session.** It is an optional second
  opinion that owns no boundaries; degrade to single-engine and keep captioning.
- **Auto-fit must be provably terminating, not tuned.** Height hysteresis cannot
  absorb a wrapped-line-count change, so shrink/grow bands oscillate forever. Any
  test for this needs a step-function height model; a linear one cannot reproduce it.
- **Closures handed to transcriber actors must not read `AppSettings.shared`** —
  it is a non-Sendable `@Observable` mutated on the main actor. Read UserDefaults.

## Known behaviors

- Filler utterances (어/음/그, bare 네네) translate to the `∅` sentinel and
  render as Korean-only rows (`TranslationFilter.isFiller`). Never let the
  model "output nothing" — it describes nothing instead, and the placeholder
  poisons the rolling context.
- Translation requests have hard timeouts (15s idle / 60s resource) because
  Anthropic SSE pings keep idle connections alive forever; without the
  resource cap a single wedged request stalls the translation queue
  permanently (the historical "translations stopped after ~38 min" bug).
- `TranslationQueue` runs 2 jobs concurrently, FIFO start order. The strict
  serial contract is still tested at `maxConcurrent: 1`.
- Capture is single-source: one of mic, all system audio, or a single app
  (`AudioSourceSelection`). `channelSpecs(for:)` always returns one `"main"`
  channel, so the transcript is one stream with no speaker attribution
  (`Utterance` has no `speaker` field; `UtteranceRow` renders timestamp /
  Korean / English only). The generic multi-channel scaffolding is still in
  place for a future dual-capture mode — `PipelineController.channelIDStride`
  (1M-apart id bands so per-stream seqs stay unique) and the `channel` field
  ("mic"/"system"/"main") on per-stream diagnostics — but nothing currently
  spawns a second channel.
- RTZR streaming STT does NOT support speaker diarization (batch-only via
  `use_diarization`); multi-speaker breakdown would need post-meeting batch
  re-processing (not built).
