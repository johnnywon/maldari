# App Icon Redesign — Design

**Date:** 2026-06-30
**Status:** Approved (design)

## Problem

The app icon is a lime→cyan gradient **"T"** — a leftover from the old name
*Translator*. The product is **Maldari (말다리)**. The Dock icon, the `.icns`,
and the menu-bar status icon all need to reflect the Maldari brand.

The icon is drawn in code (CoreGraphics), duplicated across
`AppIcon.swift` (runtime Dock icon) and `Scripts/generate-icon.swift`
(the `.icns`). The menu-bar status icon is a stock SF Symbol (`waveform`).

## Decisions (from brainstorming, with rendered previews)

**Dock / `.icns` icon — direction "C2":**
- Rounded-rect (squircle): rect inset `0.04·s`, corner radius `0.225·min`.
- Background: **horizontal lime→cyan gradient** — lime `#BBFF00` (left) →
  cyan `#5CE0D8` (right). Soft white top highlight (radial, low alpha).
- Glyph: **말** (Korean), system font heavy, ~`0.54·s`, filled dark
  ink `#0A0A12`, centered (`dy = -0.01·s`).
- Faint white hairline border, inset `0.008·s`, ~18% alpha.

**Menu-bar status icon — 말, state by glow:**
- **default** (not capturing): solid 말, **monochrome template** (auto-tints
  black/white to the menu bar).
- **live** (capturing audio, `pipeline.isListening` and not failed): 말 in the
  lime→cyan gradient with a soft green glow halo — a **colored** image
  (`isTemplate = false`), the "on-air" affordance.
- **error** (`pipeline.connectionState == .failed`): solid 말 + a small
  exclamation badge (top-right), monochrome template. Preserves the
  failed-state signal the old `waveform.badge.exclamationmark` gave.

The dropped "idle outline" state read as mush at 18px; solid-default + glow is
cleaner and gives a stronger active/inactive contrast.

## Components

### 1. Shared glyph/icon rendering (app module)

Create `Translator/Translator/MaldariIcon.swift` — the single source of the 말
artwork inside the app target:

- `MaldariIcon.malGlyphPath(in size: CGFloat, weight:) -> CGPath` — centered 말
  glyph path (uses CoreText per-run resolved font so Hangul renders via the
  system Korean face).
- `MaldariIcon.appIcon(size:) -> NSImage` — the full C2 Dock icon.
- `MaldariIcon.menuBar(_ state: MenuBarState, size:) -> NSImage` — the menu-bar
  glyph for `.default` / `.live` / `.error`, with `isTemplate` set correctly
  (true for default/error, false for live).

`enum MenuBarState { case `default`, live, error }`.

### 2. `AppIcon.swift` (runtime Dock icon)

`AppIcon.setDockIcon()` calls `MaldariIcon.appIcon(size: 512)` instead of the
old "T" drawing. The bespoke "T" drawing code is removed.

### 3. `StatusItemController.swift` (menu bar)

`refreshIcon()` maps pipeline state → `MenuBarState` and sets
`statusItem.button?.image = MaldariIcon.menuBar(state, size: 18)`:
- `.failed` → `.error`
- else `isListening` → `.live`
- else → `.default`

The initial image set in `init` uses `.default` likewise. The `waveform`
SF Symbols are removed.

### 4. `Scripts/generate-icon.swift` (the `.icns`)

Standalone script (cannot import the app module), so it keeps its **own copy**
of the C2 drawing — updated to match `MaldariIcon.appIcon`. The existing
"keep the two in sync" comment stays. It renders the iconset PNGs as today.

### 5. Regenerate `AppIcon.icns`

Run the script to an iconset dir, then
`iconutil -c icns <iconset> -o Translator/Translator/Resources/AppIcon.icns`.
Commit the regenerated binary `.icns`.

## Out of scope

- Animating the menu-bar glow (static colored image per state is enough).
- Changing the in-window source-button icon (already updated separately).
- Refactoring the standalone script to share code with the app module (the
  `swift Scripts/...` standalone-run constraint makes that not worth it now).

## Verification

- Unit: `MaldariIcon.menuBar` returns an image with the expected `isTemplate`
  per state; `malGlyphPath` is non-empty. (Pure-ish; image size assertions.)
- Visual: regenerate `.icns`, rebuild via `make-app.sh`, install to
  `/Applications`, launch; confirm the Dock shows the C2 말 tile and the
  menu bar shows solid 말 → glows lime→cyan when listening → badge on failure.
