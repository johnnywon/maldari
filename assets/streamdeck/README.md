# Stream Deck key images

Eight 288×288 PNGs — 2× the Stream Deck's native 144×144, so they stay sharp on the
newer high-DPI keys. Drag them straight onto keys in the Stream Deck app.

| File | Key | Face |
|---|---|---|
| `listen-on.png` / `listen-off.png` | Start / stop listening | 말 in lime with a halo when live, dark grey when idle |
| `subtitles-on.png` / `subtitles-off.png` | Subtitle Mode | Caption-bar screen, cyan / grey |
| `input-mic.png` / `input-system.png` | Switch input | Microphone / speaker, each with a lime ⇄ marker |
| `presentation-on.png` / `presentation-off.png` | Presentation Mode | Filled / outlined screen, lime / grey |

Only the listening key uses Hangul. The other three are symbol-led, so the four read as
four distinct silhouettes at the ~15 mm a physical key actually occupies — you find a key
by its shape before you read it.

Pair them with a Stream Deck **Hotkey** action sending the matching shortcut. Maldari has
no global hotkeys, so these fire only while Maldari is the active app:

| Shortcut | Action |
|---|---|
| ⌘L | Start / stop listening |
| ⇧⌘S | Toggle Subtitle Mode |
| ⇧⌘I | Switch input (mic ↔ system audio) |
| ⇧⌘P | Toggle Presentation Mode |

A key has no way to know Maldari's state, so pick whichever face suits how you use it —
the on/off pairs exist so you can choose, not because the icon changes by itself.

## Regenerating

These are committed rather than built, because they are dragged onto keys by hand and
need to exist without anyone running Swift first. After changing a face, re-run the
generator and commit the result with the change:

```bash
cd Translator
swift Scripts/generate-streamdeck-icons.swift
```

The palette matches the app: lime `#BBFF00`, cyan `#5CE0D8`, ink `#090910`.
