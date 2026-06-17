# Maldari (말다리) — Korean↔English live meeting translator (macOS)

SwiftPM app in `Translator/` (no xcodeproj; target keeps the Translator name,
the product/bundle is Maldari.app). Pipeline:
audio capture (mic / system / single-app) → RTZR streaming STT (WebSocket) → Claude
Haiku translation (SSE) → TranscriptStore → SwiftUI transcript panel →
SessionRecorder (disk) → CloudSyncService (your Worker).

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
