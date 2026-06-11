# Changelog

## v0.2.0.0 — 2026-06-11

The product release: Translator becomes **Maldari** (말다리, "a bridge of words").

- **Renamed**: the macOS app is now Maldari.app. Bundle id and Keychain
  service are unchanged, so existing permissions and API keys carry over.
  Logs move to `~/Library/Logs/Maldari/`, sessions to
  `~/Library/Application Support/Maldari/sessions/` (both auto-migrate).
- **Added**: cloud session sync — every session uploads as dated markdown
  (Korean + English) to your own Cloudflare Worker, live during the meeting
  (debounced ~20s) and finalized on stop. Configure in Settings → Cloud.
- **Added**: `web/` — the maldari.johnnywon.com Worker: public product
  landing page, password-gated session viewer (R2-backed, signed-cookie
  login), and the upload API the app talks to.
- **Added**: speaker attribution — the "Mic + System" dual-capture source
  runs two RTZR streams and labels each line Me (your mic) or Them (meeting
  audio); labels flow through the transcript, exports, and the web viewer.
  (RTZR streaming has no diarization; per-channel attribution is the
  deterministic alternative.)
- **Changed**: meeting-specific vocabulary (RTZR keyword boosts, translation
  glossary) moved from code into Settings, so private business terms never
  ship in the repo.

## v0.1.0.0 — 2026-06-11

Initial import of the Marathon Translator app (Korean↔English live meeting
translator for macOS), including today's reliability work:

- **Fixed**: transcript always follows the latest entry; removed the fragile
  sentinel-based "pinned to bottom" detection that silently killed auto-scroll
  mid-meeting (`defaultScrollAnchor(.bottom)` + unconditional scroll-to-bottom).
- **Fixed**: filler utterances (어/음/그, bare 네네) no longer render literal
  "(no output - filler)" placeholders. The model now emits a `∅` sentinel that
  is stripped client-side (`TranslationFilter`), and filler rows are excluded
  from the rolling translation context so the pattern can't self-reinforce.
- **Fixed**: translations no longer stop permanently mid-meeting. Translation
  requests get hard timeouts (15s idle / 60s resource — Anthropic SSE pings
  defeat idle timeouts alone), automatic retry-once, and the queue runs 2 jobs
  concurrently so one slow request can't dam the backlog.
- **Fixed**: NSLock noasync violation in TranslationQueue (Swift 6 hard error).
- **Added**: diagnostic logging (bug-killing mode) — structured JSONL per
  launch in `~/Library/Logs/Translator/` covering WebSocket drops with close
  codes, reconnects, per-translation latency (queue wait / TTFT / total),
  HTTP error bodies, and a 30s heartbeat with queue depth, audio-chunk flow,
  and STT-silence stall detection.
- **Added**: live session persistence — every finalized line and translation
  appends to `~/Library/Application Support/Translator/sessions/<stamp>/events.jsonl`
  with a rolling `transcript.md` snapshot; an app restart loses nothing.
- **Added**: Transcript menu items to open session recordings and diagnostic
  logs; regression tests for filler filtering, context exclusion, and queue
  concurrency (18 tests total).
