# Translator (Marathon)

Real-time Korean↔English meeting transcript for macOS. Audio from the
microphone or from system/process audio (Zoom, Meet in Chrome) is streamed to
RTZR's Korean STT; each finalized Korean utterance is translated to English by
Claude Haiku with rolling conversation context. The result is a live,
scrolling bilingual transcript with an optional floating subtitle mode.

## Architecture

One-way pipeline, one file per layer, protocol seams so any layer can be
swapped or mocked:

```
AudioCapturing            MicrophoneCaptureService (AVAudioEngine)
                          SystemAudioCaptureService (Core Audio process tap)
      │  AsyncStream<Data> — LINEAR16, 16 kHz mono, ~100 ms chunks
      ▼
Transcribing              RTZRStreamingService (URLSessionWebSocketTask)
      │  STTMessage — { seq, final, alternatives[].text }
      ▼
TranscriptStore           @Observable; partials mutate in place, finals append
      │  onFinalized → TranslationQueue (actor, strict FIFO)
      ▼
Translating               ClaudeTranslationService (Messages API, raw SSE)
      │  English tokens stream back into the store
      ▼
UI                        TranscriptView (main panel) · SubtitlePanel ·
                          StatusItemController (menu bar)
```

## Requirements

- macOS **14.4+** (the Core Audio process tap — `AudioHardwareCreateProcessTap`
  — requires it)
- An [RTZR / vito.ai](https://developers.rtzr.ai/) client ID + secret
- An [Anthropic API key](https://platform.claude.com/)

## Build & run

```bash
swift build                 # debug build
swift test                  # unit tests (decoder + store)
bash Scripts/make-app.sh    # release build → build/Translator.app
open build/Translator.app
```

`make-app.sh` assembles a proper .app bundle (Info.plist with the microphone
and system-audio usage strings, ad-hoc codesign with entitlements). Run the
app from the bundle — not the bare `swift run` binary — so TCC permission
grants stick.

## Smoke test

1. Launch `build/Translator.app`. Settings opens automatically on first run
   (or hit ⌘, / the gear icon in the transcript window header).
2. Enter the RTZR client ID + secret and the Anthropic API key. Press both
   **Test Connection** buttons — both should show "Connected".
3. In the transcript window header, set the source pill to **Microphone**.
4. Press **▶ Start** in the header (or the menu bar waveform icon →
   Start Listening). Approve the microphone prompt. The header dot should
   turn green (Connected).
5. Speak Korean (e.g. "안녕하세요, 오늘 회의 시작하겠습니다").
   - A **gray partial line** appears at the bottom and mutates as you speak.
   - When you pause, it locks into a **white Korean line** with a timestamp.
   - The **English translation streams in cyan** beneath it within ~a second.
6. ⌘E (or menu bar → Export Transcript…) writes a Markdown transcript to
   `~/Downloads` and reveals it in Finder.
7. For system audio: play a Korean video in Chrome, pick **System Audio**
   (or Chrome under "Apps Playing Audio") as the source, Start Listening, and
   approve the *System Audio Recording* prompt
   (System Settings → Privacy & Security → Screen & System Audio Recording →
   System Audio Recording Only).

## Permissions

| Capability | Permission | Where it's granted |
|---|---|---|
| Microphone | `NSMicrophoneUsageDescription` | prompt on first Start (mic source) |
| System audio | `NSAudioCaptureUsageDescription` | prompt on first Start (system source); manage under Privacy & Security → Screen & System Audio Recording |

If a permission was denied, the transcript window shows instructions instead
of crashing; re-grant in System Settings and restart the app.

## Known limitation: ad-hoc signing

No code-signing identity is installed on this machine, so `make-app.sh` signs
ad-hoc. Every rebuild produces a different signature, which means macOS may
re-prompt after a rebuild: the mic / system-audio TCC prompt can reappear, and
reading the stored API keys can show a Keychain "Translator wants to access…"
dialog — click **Always Allow**. Installing an Apple Development certificate
and signing with it would make both grants stick across builds.

## App Sandbox tradeoff

The sandbox is **disabled** (`com.apple.security.app-sandbox = false`).
The Core Audio process-tap API used for system-audio capture does not work
from sandboxed apps. The cost: no Mac App Store distribution and no
sandbox containment. If you only ever need microphone capture, the sandbox
could be re-enabled (with `device.audio-input`, `network.client`, and
Downloads access) at the cost of losing the System Audio source.

## API notes

- **RTZR** (verified against developers.rtzr.ai): auth at
  `POST /v1/authenticate` (form `client_id`/`client_secret` → ~6 h JWT,
  cached in memory); stream at `wss://openapi.vito.ai/v1/transcribe:streaming`
  with `sample_rate=16000&encoding=LINEAR16&model_name=sommers_ko&domain=MEETING&use_itn=true&keywords=…`;
  binary frames carry PCM; the text frame `EOS` ends a stream. Responses use
  `final` (not `is_final`) over WebSocket. Keyword boosting is one
  comma-separated param, `word` or `word:score` (−5.0…5.0, ≤100 words,
  ≤20 chars each) — editable in Settings → Transcription.
  Reconnects use exponential backoff (1 s → 30 s cap, 6 attempts) and offset
  `seq` so utterance IDs stay unique across reconnects.
- **Anthropic**: `claude-haiku-4-5-20251001` via raw `POST /v1/messages` SSE —
  no SDK. The interpreter system prompt carries
  `cache_control: {type: ephemeral}` per spec; note Haiku 4.5's minimum
  cacheable prefix is 4096 tokens, so this short prompt won't actually be
  cached — the marker is harmless and becomes useful if the glossary grows.
  Each request includes the last 10 finalized (KO, EN) pairs as alternating
  user/assistant turns for context. Translations are serialized through a
  single-worker FIFO queue (AsyncStream-fed, strict submission order) so rows
  fill in order and a slow response never blocks transcription. The Settings
  "Test Connection" button uses the free `count_tokens` endpoint.
- **Keys** live in the macOS Keychain (`com.translator.app.credentials`),
  never in UserDefaults or on disk.

## Testing

`swift test` runs canned RTZR partial/final JSON fixtures through the real
decoder and `TranscriptStore`, asserting partials mutate in place, finals
append exactly once and fire the translation hook, rolling context returns
the last 10 translated pairs, and the Markdown export format holds.
