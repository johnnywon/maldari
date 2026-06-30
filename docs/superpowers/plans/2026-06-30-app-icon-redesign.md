# App Icon Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "T" icon with the Maldari 말 wordmark (C2: lime→cyan gradient squircle, dark 말) for the Dock/`.icns`, and a 말 menu-bar status icon that glows lime→cyan while capturing.

**Architecture:** A new `MaldariIcon` enum in the app module is the single source of the 말 artwork (glyph path, full app icon, menu-bar state glyph). `AppIcon` (Dock) and `StatusItemController` (menu bar) call it. The standalone `Scripts/generate-icon.swift` keeps its own mirrored copy of the app-icon drawing (it can't import the app module) and produces the iconset, which `iconutil` packs into `AppIcon.icns`.

**Tech Stack:** Swift 5.10, AppKit, CoreGraphics/CoreText, SwiftPM, XCTest, `iconutil`.

---

## File Structure

- **Create** `Translator/Translator/MaldariIcon.swift` — the shared 말 artwork (glyph path + app icon + menu-bar state images).
- **Create** `Translator/Tests/TranslatorTests/MaldariIconTests.swift` — tests for template flags / glyph / size.
- **Modify** `Translator/Translator/AppIcon.swift` — Dock icon delegates to `MaldariIcon`.
- **Modify** `Translator/Translator/StatusItemController.swift` — menu-bar icon uses `MaldariIcon` state glyphs.
- **Modify** `Translator/Scripts/generate-icon.swift` — mirror the C2 app-icon drawing.
- **Regenerate** `Translator/Translator/Resources/AppIcon.icns` (binary asset).

**Commands (run from `Translator/`):** build `DEVELOPER_DIR=/Applications/Xcode.app swift build`; test `DEVELOPER_DIR=/Applications/Xcode.app swift test`.

---

### Task 1: `MaldariIcon` shared artwork + tests

**Files:**
- Create: `Translator/Translator/MaldariIcon.swift`
- Test: `Translator/Tests/TranslatorTests/MaldariIconTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Translator/Tests/TranslatorTests/MaldariIconTests.swift`:

```swift
import XCTest
import AppKit
@testable import Translator

final class MaldariIconTests: XCTestCase {
    func test_malGlyphPath_isNonEmpty() {
        XCTAssertFalse(MaldariIcon.malGlyphPath(in: 100, weight: .heavy).isEmpty)
    }
    func test_menuBar_defaultAndError_areTemplateImages() {
        XCTAssertTrue(MaldariIcon.menuBar(.default).isTemplate)
        XCTAssertTrue(MaldariIcon.menuBar(.error).isTemplate)
    }
    func test_menuBar_live_isColoredNotTemplate() {
        XCTAssertFalse(MaldariIcon.menuBar(.live).isTemplate)
    }
    func test_appIcon_hasRequestedSize() {
        XCTAssertEqual(MaldariIcon.appIcon(size: 256).size, NSSize(width: 256, height: 256))
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift test --filter MaldariIconTests`
Expected: FAIL — `cannot find 'MaldariIcon' in scope`.

- [ ] **Step 3: Implement `MaldariIcon`**

Create `Translator/Translator/MaldariIcon.swift`:

```swift
import AppKit
import CoreText

/// Single source of the Maldari 말 artwork: the C2 app icon (Dock / `.icns`)
/// and the menu-bar status glyph. NOTE: `Scripts/generate-icon.swift` keeps
/// its own mirrored copy of `appIcon`'s drawing for the standalone `.icns`
/// build (it can't import this module) — keep the two in sync.
enum MaldariIcon {

    // Brand palette (mirrors Theme.limeNS / Theme.cyanNS).
    private static let lime = NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 1)
    private static let cyan = NSColor(red: 92/255, green: 224/255, blue: 216/255, alpha: 1)
    private static let ink  = NSColor(red: 9/255, green: 9/255, blue: 16/255, alpha: 1)

    enum MenuBarState { case `default`, live, error }

    /// Centered 말 glyph path. Uses CoreText so Hangul resolves via the system
    /// Korean face (the base SF font has no 말 glyph of its own).
    static func malGlyphPath(in s: CGFloat, weight: NSFont.Weight, dy: CGFloat = 0) -> CGPath {
        let font = NSFont.systemFont(ofSize: s * 0.74, weight: weight)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "말", attributes: [.font: font]))
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let tx = (s - b.width) / 2 - b.minX
        let ty = (s - b.height) / 2 - b.minY + dy
        let path = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line)
        for i in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, i), to: CTRun.self)
            let rf = unsafeBitCast(CFDictionaryGetValue(CTRunGetAttributes(run),
                Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()), to: CTFont.self)
            let gc = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: gc)
            var pos = [CGPoint](repeating: .zero, count: gc)
            CTRunGetGlyphs(run, CFRange(location: 0, length: gc), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: gc), &pos)
            for j in 0..<gc {
                if let gp = CTFontCreatePathForGlyph(rf, glyphs[j], nil) {
                    var t = CGAffineTransform(translationX: tx + pos[j].x, y: ty + pos[j].y)
                    if let mp = gp.copy(using: &t) { path.addPath(mp) }
                }
            }
        }
        return path
    }

    /// Full C2 Dock / `.icns` icon: lime→cyan gradient squircle with a dark 말.
    static func appIcon(size s: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            let rect = CGRect(x: s*0.04, y: s*0.04, width: s*0.92, height: s*0.92)
            let radius = min(rect.width, rect.height) * 0.225
            let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

            ctx.saveGState(); bg.addClip()
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [lime.cgColor, cyan.cgColor] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.midY),
                                       end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
            }
            if let gl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [NSColor(white: 1, alpha: 0.16).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1]) {
                let c = CGPoint(x: rect.midX, y: rect.maxY)
                ctx.drawRadialGradient(gl, startCenter: c, startRadius: 0, endCenter: c, endRadius: s*0.55, options: [])
            }
            ctx.restoreGState()

            ctx.saveGState()
            let bp = NSBezierPath(roundedRect: rect.insetBy(dx: s*0.008, dy: s*0.008), xRadius: radius, yRadius: radius)
            bp.lineWidth = s*0.01
            NSColor(white: 1, alpha: 0.18).setStroke(); bp.stroke()
            ctx.restoreGState()

            ink.setFill()
            ctx.addPath(malGlyphPath(in: s, weight: .heavy, dy: -s*0.01))
            ctx.fillPath()
            return true
        }
    }

    /// Menu-bar status glyph. `.default`/`.error` are monochrome **template**
    /// images that auto-tint to the bar; `.live` is a colored lime→cyan glowing
    /// glyph (the "capturing" affordance).
    static func menuBar(_ state: MenuBarState, size s: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            let glyph = malGlyphPath(in: s, weight: .heavy)
            switch state {
            case .default:
                NSColor.black.setFill(); ctx.addPath(glyph); ctx.fillPath()
            case .error:
                NSColor.black.setFill(); ctx.addPath(glyph); ctx.fillPath()
                let r = s*0.22, bx = s - r, by = s - r
                NSBezierPath(ovalIn: CGRect(x: bx - r/2, y: by - r/2, width: r, height: r)).fill()
                ctx.setBlendMode(.clear)
                ctx.fill(CGRect(x: bx - s*0.018, y: by - s*0.05, width: s*0.036, height: s*0.07))
                ctx.fillEllipse(in: CGRect(x: bx - s*0.022, y: by - s*0.082, width: s*0.044, height: s*0.03))
                ctx.setBlendMode(.normal)
            case .live:
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: s*0.16,
                              color: NSColor(red: 0.55, green: 0.95, blue: 0.55, alpha: 0.95).cgColor)
                cyan.setFill(); ctx.addPath(glyph); ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState(); ctx.addPath(glyph); ctx.clip()
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [lime.cgColor, cyan.cgColor] as CFArray, locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: s*0.18, y: s/2),
                                           end: CGPoint(x: s*0.82, y: s/2), options: [])
                }
                ctx.restoreGState()
            }
            return true
        }
        img.isTemplate = (state != .live)
        return img
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift test --filter MaldariIconTests`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Translator/Translator/MaldariIcon.swift Translator/Tests/TranslatorTests/MaldariIconTests.swift
git commit -m "$(cat <<'EOF'
feat(icon): MaldariIcon — shared 말 artwork for app + menu bar

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Dock icon uses `MaldariIcon`

**Files:**
- Modify: `Translator/Translator/AppIcon.swift`

- [ ] **Step 1: Confirm `generateIcon` has no other callers**

Run: `cd Translator && grep -rn "AppIcon.generateIcon\|generateIcon(" Translator/ Tests/ | grep -v ".build"`
Expected: only matches inside `AppIcon.swift` itself (the definition + `setDockIcon`). If any other caller exists, STOP and report.

- [ ] **Step 2: Replace the file contents**

Replace the entire contents of `Translator/Translator/AppIcon.swift` with:

```swift
import AppKit

/// Sets the Dock icon to the Maldari 말 mark (drawn by `MaldariIcon`).
enum AppIcon {
    static func setDockIcon() {
        NSApp.applicationIconImage = MaldariIcon.appIcon(size: 512)
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift build`
Expected: Build succeeds (the old `generateIcon` "T" drawing is gone, nothing references it).

- [ ] **Step 4: Commit**

```bash
git add Translator/Translator/AppIcon.swift
git commit -m "$(cat <<'EOF'
feat(icon): Dock icon uses MaldariIcon 말 mark

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Menu-bar icon uses `MaldariIcon` states

**Files:**
- Modify: `Translator/Translator/StatusItemController.swift`

- [ ] **Step 1: Replace the initial image in `init`**

In `init(pipeline:)`, replace this line:

```swift
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Maldari")
```

with:

```swift
        statusItem.button?.image = MaldariIcon.menuBar(.default)
        statusItem.button?.image?.accessibilityDescription = "Maldari"
```

- [ ] **Step 2: Replace `refreshIcon()`**

Replace the entire `refreshIcon()` method with:

```swift
    private func refreshIcon() {
        let state: MaldariIcon.MenuBarState
        if case .failed = pipeline.connectionState {
            state = .error
        } else {
            state = pipeline.isListening ? .live : .default
        }
        let image = MaldariIcon.menuBar(state)
        image.accessibilityDescription = "Maldari"
        statusItem.button?.image = image
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift build`
Expected: Build succeeds; no remaining `systemSymbolName: "waveform"` references.

Verify: `grep -n "waveform" Translator/Translator/StatusItemController.swift` → no matches.

- [ ] **Step 4: Commit**

```bash
git add Translator/Translator/StatusItemController.swift
git commit -m "$(cat <<'EOF'
feat(icon): menu-bar 말 status icon — glows while capturing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Mirror C2 drawing into the standalone icns script

**Files:**
- Modify: `Translator/Scripts/generate-icon.swift`

- [ ] **Step 1: Replace the `generateIcon(size:)` function body**

In `Translator/Scripts/generate-icon.swift`, replace the entire `func generateIcon(size:) -> NSImage { ... }` (the drawing that renders the dark "T") with the C2 drawing below. Keep the file's other parts (`import`s, `writePNG`, the `main` arg parsing + size `plan` loop) unchanged.

```swift
func generateIcon(size: CGFloat) -> NSImage {
    let lime = NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 1)
    let cyan = NSColor(red: 92/255, green: 224/255, blue: 216/255, alpha: 1)
    let ink  = NSColor(red: 9/255, green: 9/255, blue: 16/255, alpha: 1)
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let s = size
        let rect = CGRect(x: s*0.04, y: s*0.04, width: s*0.92, height: s*0.92)
        let radius = min(rect.width, rect.height) * 0.225
        let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        ctx.saveGState(); bg.addClip()
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [lime.cgColor, cyan.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.midY),
                                   end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
        }
        if let gl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor(white: 1, alpha: 0.16).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1]) {
            let c = CGPoint(x: rect.midX, y: rect.maxY)
            ctx.drawRadialGradient(gl, startCenter: c, startRadius: 0, endCenter: c, endRadius: s*0.55, options: [])
        }
        ctx.restoreGState()

        ctx.saveGState()
        let bp = NSBezierPath(roundedRect: rect.insetBy(dx: s*0.008, dy: s*0.008), xRadius: radius, yRadius: radius)
        bp.lineWidth = s*0.01
        NSColor(white: 1, alpha: 0.18).setStroke(); bp.stroke()
        ctx.restoreGState()

        // 말 glyph (CoreText so Hangul resolves via the system Korean face)
        let font = NSFont.systemFont(ofSize: s * 0.54, weight: .heavy)
        let lineCT = CTLineCreateWithAttributedString(NSAttributedString(string: "말", attributes: [.font: font]))
        let b = CTLineGetBoundsWithOptions(lineCT, .useGlyphPathBounds)
        let tx = (s - b.width) / 2 - b.minX
        let ty = (s - b.height) / 2 - b.minY - s*0.01
        let textPath = CGMutablePath()
        let runs = CTLineGetGlyphRuns(lineCT)
        for i in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, i), to: CTRun.self)
            let rf = unsafeBitCast(CFDictionaryGetValue(CTRunGetAttributes(run),
                Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()), to: CTFont.self)
            let gc = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: gc)
            var positions = [CGPoint](repeating: .zero, count: gc)
            CTRunGetGlyphs(run, CFRange(location: 0, length: gc), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: gc), &positions)
            for j in 0..<gc {
                if let gp = CTFontCreatePathForGlyph(rf, glyphs[j], nil) {
                    var transform = CGAffineTransform(translationX: tx + positions[j].x, y: ty + positions[j].y)
                    if let moved = gp.copy(using: &transform) { textPath.addPath(moved) }
                }
            }
        }
        ink.setFill(); ctx.addPath(textPath); ctx.fillPath()
        return true
    }
}
```

Also ensure `import CoreText` is present near the top of the file (it already imports `AppKit`, `CoreText`, `Foundation`).

- [ ] **Step 2: Smoke-run the script to a scratch iconset**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift Scripts/generate-icon.swift /tmp/Maldari.iconset`
Expected: prints `wrote icon_16x16.png` … through `icon_512x512@2x.png`, no errors.

- [ ] **Step 3: Commit**

```bash
git add Translator/Scripts/generate-icon.swift
git commit -m "$(cat <<'EOF'
feat(icon): mirror C2 말 drawing in the icns generator

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Regenerate `.icns`, rebuild, install, verify

**Files:**
- Modify (binary): `Translator/Translator/Resources/AppIcon.icns`

- [ ] **Step 1: Pack the iconset into the bundle `.icns`**

Run (from `Translator/`):
```bash
cd Translator
DEVELOPER_DIR=/Applications/Xcode.app swift Scripts/generate-icon.swift /tmp/Maldari.iconset
iconutil -c icns /tmp/Maldari.iconset -o Translator/Resources/AppIcon.icns
file Translator/Resources/AppIcon.icns
```
Expected: `AppIcon.icns: Mac OS X icon` (valid icns).

- [ ] **Step 2: Run the full test suite**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift test`
Expected: all tests pass (existing + `MaldariIconTests`).

- [ ] **Step 3: Build + install the app**

Run:
```bash
cd Translator && bash Scripts/make-app.sh Release
rm -rf /Applications/Maldari.app && ditto build/Maldari.app /Applications/Maldari.app
codesign --verify --strict /Applications/Maldari.app && echo "sig OK"
```
Expected: build completes, signature OK.

- [ ] **Step 4: Launch and verify visually**

Run: `open /Applications/Maldari.app` then capture the screen:
`screencapture -x /tmp/maldari-verify.png`
Confirm by viewing the screenshot:
- Dock / app icon = lime→cyan 말 tile (not the "T").
- Menu bar = solid 말 (default). (Press Start Listening → it glows lime→cyan; a failed connection → 말 + badge.)

Note: macOS may re-prompt for Microphone / System Audio permission because the bundle was re-signed.

- [ ] **Step 5: Commit the regenerated icns**

```bash
git add Translator/Translator/Resources/AppIcon.icns
git commit -m "$(cat <<'EOF'
feat(icon): regenerate AppIcon.icns with the 말 mark

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- C2 Dock/`.icns` drawing (gradient squircle + dark 말 + highlight + hairline) → Task 1 (`appIcon`) + Task 4 (script mirror) + Task 5 (`.icns`). ✓
- Shared `MaldariIcon` (glyph path / app icon / menu-bar state) → Task 1. ✓
- `AppIcon` Dock delegates to it → Task 2. ✓
- Menu-bar states default/live/error mapped from pipeline state → Task 3. ✓ (`.failed`→error, `isListening`→live, else default — matches spec.)
- `generate-icon.swift` mirrored → Task 4. ✓
- Regenerate `.icns` → Task 5. ✓
- Verification (unit template flags + visual) → Task 1 tests + Task 5 steps. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `MaldariIcon.menuBar(_:size:)`, `MaldariIcon.MenuBarState` (`.default`/`.live`/`.error`), `MaldariIcon.appIcon(size:)`, `MaldariIcon.malGlyphPath(in:weight:dy:)` are used identically in Tasks 1–3. The script in Task 4 deliberately does NOT reference `MaldariIcon` (standalone). `pipeline.connectionState`/`isListening` match `StatusItemController`'s existing usage. ✓
