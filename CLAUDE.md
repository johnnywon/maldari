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

- **Keyboard shortcuts live in the SwiftUI `.commands` block, not on the status item.**
  A status item's menu `keyEquivalent`s fire only while that menu is open, so they are
  labels rather than shortcuts. The main menu built in `TranslatorApp.body.commands` is
  what actually binds ⌘L / ⇧⌘S / ⇧⌘P / ⇧⌘T / ⇧⌘I, and those work whenever Maldari is the
  active app. There are deliberately NO global hotkeys — a Stream Deck drives the app by
  sending these keystrokes while Maldari is frontmost. Because that is invisible to the
  operator (during a call the call app holds focus and every shortcut is dead), the
  status menu carries a disabled "Shortcuts work while Maldari is frontmost" row, and its
  `keyEquivalent`s exist only to print the real bindings — keep the two in step.
- **⇧⌘S refuses while Presentation Mode is on rather than toggling.** Presentation Mode
  already forces Subtitle Mode off through the 0.25 s settings poll, so flipping the flag
  would be undone with nothing on screen to explain it. `AppDelegate.toggleSubtitleMode()`
  guards on `presentationMode` so every caller inherits the rule.
- **The panel prints the source name, and the name says whose voice it is.** "Microphone"
  vs "System Audio" described devices; the operator could not tell mid-meeting whether
  Maldari was hearing them or hearing the call. The menus now read "Microphone (your
  voice)" / "All system audio (what your Mac plays)", and the panel shows
  `AudioSourceSelection.shortLabel` beside the icon. `shortLabel` is separate from
  `displayName` because the control island is centred between two fixed 96 pt side zones,
  so app names truncate at 14 characters — a rule that belongs in the model where it is
  testable, not in the view.
- **The source cycle has one implementation, `AudioSourceSelection.nextInSourceCycle`.**
  Both the transcript panel's source pill and ⇧⌘I go through it; it used to be written
  inline in the pill. Mic ↔ system audio only — per-app sources are a list that changes
  while the app runs, so a cycle through them would make the same press do something
  different minute to minute. The `switch` is exhaustive on purpose, so a new source case
  fails to compile rather than silently joining the cycle.
- **The 말 glyph-drawing code exists in three places** — `Translator/MaldariIcon.swift`,
  `Scripts/generate-icon.swift` and `Scripts/generate-streamdeck-icons.swift`. A
  standalone `swift` script cannot import the app module, so each keeps its own CoreText
  copy. Change the treatment in one and you must change all three.
- **`assets/streamdeck/` is committed output, unlike `generate-icon.swift`'s.** Those PNGs
  are dragged onto Stream Deck keys by hand, so they have to exist without anyone running
  Swift first. Re-run the generator and commit the result whenever a face changes.
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
- Capture selects ONE source (`AudioSourceSelection`: mic, all system audio, or
  a single app) but `channelSpecs(for:)` may open several CHANNELS over it, per
  `CaptureMode`. `koreanOnly` returns one `"main"` channel; both bidirectional
  modes return two. `bidirectionalSingle` captures the SAME source twice, at two
  sample rates, because one capture cannot emit both 16 kHz (RTZR) and 24 kHz
  (OpenAI). The multi-channel scaffolding is therefore live, not aspirational:
  `PipelineController.channelIDStride` (1M-apart id bands keeping per-stream
  seqs unique) and the `channel` field on per-stream diagnostics are both load
  bearing. There is still no speaker attribution — `Utterance` has no `speaker`
  field and `UtteranceRow` renders timestamp / Korean / English only.
- RTZR streaming STT does NOT support speaker diarization (batch-only via
  `use_diarization`); multi-speaker breakdown would need post-meeting batch
  re-processing (not built).

## Testing traps that have actually bitten

- **A live STT test whose audio ENDS cannot see a segmenter that never
  segments.** `OpenAIRealtimeSTTService.finishStream()` sends
  `input_audio_buffer.commit` as EOS, which forces the server to emit a final.
  So when a test's fixture runs out of audio, a final arrives no matter how
  broken turn detection is. A real meeting's mic never runs out, so the app got
  no final at all and nothing translated. This mistake was made twice — once in
  the unit-level live test, then again in the end-to-end fixture written to
  catch it. Fixtures must hold the mic open (stream silence indefinitely, end
  only on `stop()`), and the assertion must be that a final arrives BEFORE the
  audio stops.
- **Prove a new regression test can fail.** Both blind tests above were caught
  by mutating `turn_detection` to `NSNull()` and confirming the test still
  passed — with a complete, correct transcript, which is what made it so
  convincing. A green test is evidence of nothing until you have watched it go
  red for the right reason.
- **Per-leg tests passing is not integration.** The engines transcribed, the
  translator translated, the debate arbitrated — every one green — while the
  window showed an empty column. The bug was in the seam. Keep the end-to-end
  live tests (`test_endToEnd_*`) honest; they are the only ones that exercise
  what the user actually sees.

## Performance invariants (measured, with guards)

`PerfBaselineTests` characterises these and asserts each one. They are cheap and
hermetic; run them before believing any optimisation.

**They measure thread CPU time (`CLOCK_THREAD_CPUTIME_ID`), never wall-clock.** Every
guard here is a claim about how much work a code path does, and wall-clock cannot
separate that from how busy the machine is — it counts time the scheduler had us
descheduled. On wall-clock the per-token guard read 12.6-16.2 µs idle against its 20 µs
bar and failed roughly one run in ten, and 20-52 µs with eight cores busy, while the
O(1) shape it exists to guard sat at ~0.95x the whole time. Two plausible-looking
repairs do not work: taking the minimum of N samples (under sustained load every sample
is contaminated) and dividing by a calibration op (a tight arithmetic loop keeps its
scheduler slot while an allocating path does not, so the quotient spread 36x-190x).
Thread CPU time is much less load-sensitive, but it is not load-proof: under heavy
contention the same work costs more cycles, because caches and memory bandwidth are
contended. The per-token guard reads 9.8-13.7 µs on a quiet machine and 17.5-20.9 µs
with a browser, Finder and a video call running, so its bar is 32 µs — the geometric
midpoint of the worst measured noise (20.9 µs) and the regression it exists to catch
(51.27 µs). Set an absolute bar from that midpoint, never from quiet-machine readings
alone; a 20 µs bar chosen that way failed during an ordinary working session. The RATIO
assertions need no such allowance — they held at 0.87x-1.19x through every condition
measured, including eight saturated cores, and are the half of these tests to trust.

- **The live window must not re-render at provider token rate.** Translation writes
  to the store are coalesced to `PipelineController.uiFlushInterval` (1/30 s). This
  is lossless ONLY because these writes are absolute, not incremental — each carries
  the whole accumulated string, so a dropped value is one the next write fully
  supersedes, and both streaming loops write the authoritative text again after the
  loop. If the streaming protocol ever changes to send deltas, this throttle becomes
  a correctness bug; `StreamCoalescingTests` fails if it does.
- **Nothing on a per-token path may scan the whole meeting.** `historyEntries` takes
  `suffix(depth + 1)` before filtering (`historyDepth` never exceeds 3);
  `contextPairs` walks back from the cursor. Both were O(N) and both are evaluated
  per token.
- **Nothing on a per-token path may do refusal analysis.** `TranslationFilter.isFiller`
  lowercases its input and runs ~43 substring searches — 74 µs on a sentence, and it
  grows as the translation streams. Mid-stream use `isSentinel` (0.26 µs); a refusal
  is a property of a COMPLETED response, and the completion paths still check in full.
- **One store mutation per token, not two.** Mutating `target` and then `targetText`
  through the subscript is two writes to an @Observable array and SwiftUI rebuilds on
  each. Mutate a local copy and assign once.
- **The transcript panel must not float over the Presentation window.**
  `TranslatorPanel` is `.floating` + `.canJoinAllSpaces` + `.fullScreenAuxiliary` with
  `.behindWindow` blending, so it follows the operator into the Presentation window's
  full-screen space and makes the window server re-blur the caption surface
  continuously. This is the only mechanism here that can slow the *system* pointer —
  an app saturating its own main thread stutters its own UI, it does not lag the
  cursor. Suppressed by `TranscriptPanelPolicy`; worth 17 MB of footprint and 67 MB
  of peak.
- **Nothing blocking or unbounded on the main actor.** `SessionRecorder` snapshots go
  to a serial background queue — it is a whole-file atomic write that grows all
  meeting and whose tail latency depends on Spotlight/FileVault/Time Machine, not on
  us. `exportMarkdown`'s formatters are statics; `DateFormatter()` costs ~100-200 µs
  to construct.
- **The 0.25 s settings poll must be idempotent.** It runs 14,400 times an hour;
  assigning `backgroundColor` allocates and dirties a translucent window and
  assigning `level` is a window-server round trip. Guard every write on change.

Where the memory actually is: the transcript is ~2 KB per utterance, under 1 MB for
an hour, and a 240 s live soak with real sockets and the real debate grew 0.3 MB.
Memory complaints are about window-server surfaces, not the model layer.
