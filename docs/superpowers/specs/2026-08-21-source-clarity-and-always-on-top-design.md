# Source clarity + Always-on-Top shortcut

Date: 2026-08-21

## Problem

Three separate reports from one session of live use:

1. "Where is the keyboard shortcut for subtitles?" — ⇧⌘S exists
   (`TranslatorApp.swift:43`) but the status-bar menu prints no key next to
   Subtitle Mode, and prints ⌘P next to Presentation Mode when the real binding
   is ⇧⌘P. Worse, shortcuts only fire while Maldari is frontmost, which during a
   Zoom call it never is. Nothing in the UI says so.
2. No way to toggle Always on Top from the keyboard. The setting exists
   (`AppSettings.alwaysOnTop`) and is reachable only from the gear menu and
   Settings.
3. The panel's source control is a single icon that cycles. Mid-meeting the
   operator cannot tell whether it is capturing their own microphone or the
   call's audio, and the difference between "Microphone" and "System Audio" was
   not clear in the first place.

## Scope

Discoverability and labelling only. Global hotkeys stay out of scope — their
absence is a deliberate existing decision (see CLAUDE.md).

## Design

### 1. ⇧⌘T — Always on Top

`AppDelegate.toggleAlwaysOnTop()` flips `settings.alwaysOnTop`. No window code:
the 0.25 s settings poll already maps the flag to the panel's window level
(`TranslatorApp.swift:185`) and its writes are guarded on change, so the poll
stays idempotent.

Wired in two places, matching the existing pattern for the other three toggles:
- a `Button` in the Transcript `CommandMenu` with
  `.keyboardShortcut("t", modifiers: [.command, .shift])` — this is what
  actually binds the key;
- a checkmarked `Always on Top` row in the status-bar menu, state refreshed in
  `menuWillOpen` alongside `subtitleItem` and `presentationItem`.

No guard against Presentation Mode: the panel's level is independent of it.

### 2. Source label in the panel

`TranscriptView.sourceButton` becomes icon + text instead of icon alone. Left
click still cycles mic ↔ system audio via `nextInSourceCycle`; right click still
opens the full list including single apps.

The text comes from one new pure function on `AudioSourceSelection`:

    var shortLabel: String   // "Microphone" | "System audio" | truncated app name

It is separate from the existing `displayName` because the panel has a hard
width budget the menus do not: the control island is centred between two 96 pt
side zones, and an untruncated app name would push it off centre. Process names
truncate to 14 characters plus an ellipsis. The label renders `lineLimit(1)` with
`.truncationMode(.tail)` as a second line of defence.

One implementation shared by the panel and the status line, for the same reason
`nextInSourceCycle` has one: two copies drift.

The right-click entries gain the distinction the operator actually needed:
`Microphone (your voice)` and `All system audio (what your Mac plays)`.

### 3. Status-menu shortcut labels

Set the real modifiers on the status-menu rows so what is printed matches what
is bound:

| Row | Printed |
|---|---|
| Start/Stop Listening | ⌘L |
| Open Transcript | ⌘0 |
| Export Transcript… | ⌘E |
| Subtitle Mode | ⇧⌘S |
| Presentation Mode | ⇧⌘P |
| Always on Top | ⇧⌘T |

These remain labels, not bindings — a status item's key equivalents fire only
while its menu is open. That is precisely why the printed text must be right:
it is documentation, and it was wrong.

Add one disabled row beneath the toggles: *Shortcuts work while Maldari is
frontmost*. This is the fact that made ⇧⌘S look broken during a Zoom call.

## Testing

`SourceCycleTests` gains cases for `shortLabel`: microphone, system audio, a
short app name (passes through), and a long app name (truncated, with the
ellipsis, bounded length). The rest is menu and command wiring, verified by
building and running.

## Not doing

- Global hotkeys.
- A dropdown listing all three sources in the panel (considered; the cycling
  control plus a label was chosen as the smaller change).
- Auto-selecting the running call app.
