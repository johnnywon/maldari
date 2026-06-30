# Subtitle Display Picker — Design

**Date:** 2026-06-30
**Status:** Approved (design); pending spec review

## Problem

In a multi-monitor setup, the floating subtitle overlay (`SubtitlePanel`) always
pins itself to the *physically topmost* display — the screen whose top edge is
highest (leftmost wins ties). This is deliberate (it stops captions from
"wandering" to whatever screen was last clicked), but it gives the user **no way
to choose a display**. The overlay is borderless and click-through
(`ignoresMouseEvents = true`), so it can't be dragged either, and a 0.25s poll
re-homes it on any display change.

Real-world failure: on a video call across two screens, captions landed on the
topmost display instead of the screen with the camera the user was looking at.

## Goal

Let the user pick which connected display the subtitle captions appear on, with a
graceful fallback when that display isn't connected.

## Decisions (locked during brainstorming)

- **Interaction:** a remembered **display picker** in the menu (and Settings) —
  not drag, not a cycle hotkey.
- **Default & fallback:** `Automatic (topmost)` is the default option and the
  fallback. If the chosen display isn't connected, captions still show on the
  best-guess (topmost) screen and **snap back** to the chosen display the moment
  it reconnects. Captions are never silently lost.
- **Identity:** displays are remembered by `localizedName` (human-readable,
  matches the picker).

## Approach

Persist the chosen display's name and resolve it to a live `NSScreen` at
positioning time, falling back to the existing topmost rule. Chosen over a
`CGDisplayCreateUUID` identity (more robust but opaque, needs a name map anyway,
clunkier APIs) and over remembering a saved frame/origin (fragile across
resolution changes, doesn't map to a picker).

## Components

### 1. Setting — `AppSettings`

Add:

```swift
/// localizedName of the display the subtitle panel should use.
/// Empty string = Automatic (topmost). Falls back to topmost when the
/// named display isn't connected.
var subtitleDisplayName: String {
    didSet { UserDefaults.standard.set(subtitleDisplayName, forKey: "subtitleDisplayName") }
}
```

Register default `"subtitleDisplayName": ""` and load it in `init`, exactly like
the sibling subtitle settings.

### 2. Screen selection — `SubtitlePanel` + a pure helper

Extract the selection *rule* into a pure, testable helper that operates on an
abstract screen list (no `NSScreen` dependency):

```swift
enum DisplayChoice {
    struct Screen { let name: String; let frame: CGRect }

    /// Index of the target screen: the connected screen whose name matches
    /// `name`, else the topmost (highest `frame.maxY`; smallest `minX` on a
    /// tie). Returns nil only for an empty screen list.
    static func index(named name: String, in screens: [Screen]) -> Int?
}
```

`SubtitlePanel` maps `NSScreen.screens` → `[DisplayChoice.Screen]` (using
`localizedName` + `frame`), calls the helper, and resolves the index back to the
`NSScreen`. The existing static `frame()` becomes `frame(displayName:)` (still
static, so it remains callable from `super.init(contentRect:)` where `settings`
is the local init parameter). `applyPosition()` calls
`Self.frame(displayName: settings.subtitleDisplayName)`.

The current `topmostScreen` tiebreak (`(maxY, -minX)`) moves into the helper so
both name-match and topmost-fallback are covered by one tested rule.

### 3. Re-homing — no new wiring

`TranslatorApp.applySettings()` already runs on a 0.25s timer and calls
`subtitlePanel?.applyPosition()`, which only `setFrame`s when the target frame
changed. Therefore:

- changing the picker → next tick moves the overlay,
- the chosen display reconnecting → next tick snaps it back,
- the chosen display disconnecting → next tick falls back to topmost.

No new timers, notifications, or `NSApplication.didChangeScreenParameters`
observers are needed.

### 4. Menu picker — `StatusItemController`

Add a **"Subtitle Display"** submenu, rebuilt on `menuWillOpen` like the existing
**Audio Source** submenu (`rebuildSourceMenu`):

- `Automatic (topmost)` — checked when `subtitleDisplayName` is empty; selecting
  sets it to `""`.
- one item per connected display (`localizedName`) — checked when it matches the
  stored name; selecting sets `subtitleDisplayName` to that name.
- if the stored choice is non-empty and not currently connected, append a
  **disabled** `"<name> (not connected)"` row so the remembered choice stays
  visible.

### 5. Settings picker — `PreferencesView`

Add a `Picker("Display", selection: $settings.subtitleDisplayName)` in the
subtitle section:

- `Text("Automatic (topmost)").tag("")`
- one tagged row per connected display (`localizedName`)
- if the stored name isn't among connected displays, include it as an extra
  `"<name> (not connected)"` tagged row so the Picker reflects the saved value

It inherits the section's existing `.disabled(!settings.subtitleMode)` /
`.opacity(...)` treatment.

## Testing

`DisplayChoiceTests` (pure, no real display required):

- name match → that screen's index wins
- non-empty name not present → topmost index
- empty name → topmost index
- top-edge tie → leftmost (smallest `minX`) index
- duplicate names → first matching index
- empty screen list → nil

## Known limitation (deferred — YAGNI)

Two identical monitor models share a `localizedName`; ties resolve to the first
match. Acceptable for v1. The upgrade path is UUID-based identity
(`CGDisplayCreateUUID`) if this ever causes confusion.

## Out of scope

- Free-dragging the overlay anywhere on a screen.
- A "move to next display" hotkey.
- Per-display position/size overrides (the existing Top/Bottom and caption-size
  settings remain global).
