# Subtitle Display Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose which connected display the floating subtitle overlay appears on, defaulting to (and falling back to) Automatic/topmost.

**Architecture:** A pure, unit-tested helper (`DisplayChoice`) decides the target display from a chosen name and the connected screen list (name match, else topmost). `SubtitlePanel` feeds it `NSScreen.screens` and positions itself on the result. A new `AppSettings.subtitleDisplayName` (empty = Automatic) persists the choice; the existing 0.25s settings poll already calls `applyPosition()`, so picking a display or (dis)connecting one re-homes the overlay with no new wiring. The choice is set from a menu-bar submenu and a Settings picker.

**Tech Stack:** Swift 5.10, SwiftPM, AppKit (`NSPanel`/`NSScreen`/`NSMenu`), SwiftUI, XCTest.

---

## File Structure

- **Create** `Translator/Translator/Support/DisplayChoice.swift` — pure display-selection rule (no AppKit dependency beyond `CGRect`).
- **Create** `Translator/Tests/TranslatorTests/DisplayChoiceTests.swift` — tests for the rule.
- **Modify** `Translator/Translator/AppSettings.swift` — add `subtitleDisplayName`.
- **Modify** `Translator/Translator/Views/SubtitlePanel.swift` — resolve target screen via `DisplayChoice`.
- **Modify** `Translator/Translator/StatusItemController.swift` — "Subtitle Display" submenu.
- **Modify** `Translator/Translator/Views/PreferencesView.swift` — "Display" picker + `import AppKit`.

SPM auto-includes files under the target paths, so no `Package.swift` change is needed.

**Build/test commands (run from `Translator/`):**
- Build: `DEVELOPER_DIR=/Applications/Xcode.app swift build`
- Test: `DEVELOPER_DIR=/Applications/Xcode.app swift test`

---

### Task 1: `DisplayChoice` pure selection rule

**Files:**
- Create: `Translator/Translator/Support/DisplayChoice.swift`
- Test: `Translator/Tests/TranslatorTests/DisplayChoiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Translator/Tests/TranslatorTests/DisplayChoiceTests.swift`:

```swift
import XCTest
@testable import Translator

final class DisplayChoiceTests: XCTestCase {

    /// macOS screen frames are bottom-left origin; `maxY` is the top edge.
    private func screen(_ name: String, x: CGFloat, y: CGFloat,
                        w: CGFloat = 1000, h: CGFloat = 1000) -> DisplayChoice.Screen {
        DisplayChoice.Screen(name: name, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    func test_nameMatch_winsOverTopmost() {
        let screens = [
            screen("Built-in", x: 0, y: 0),        // top edge 1000
            screen("DELL", x: 1000, y: 500),       // top edge 1500 (topmost)
        ]
        XCTAssertEqual(DisplayChoice.index(named: "Built-in", in: screens), 0)
    }

    func test_missingName_fallsBackToTopmost() {
        let screens = [
            screen("Built-in", x: 0, y: 0),        // 1000
            screen("DELL", x: 1000, y: 500),       // 1500 (topmost)
        ]
        XCTAssertEqual(DisplayChoice.index(named: "Unplugged", in: screens), 1)
    }

    func test_emptyName_usesTopmost() {
        let screens = [
            screen("Built-in", x: 0, y: 0),        // 1000
            screen("DELL", x: 1000, y: 500),       // 1500 (topmost)
        ]
        XCTAssertEqual(DisplayChoice.index(named: "", in: screens), 1)
    }

    func test_topEdgeTie_prefersLeftmost() {
        let screens = [
            screen("Right", x: 1000, y: 0),        // top 1000, minX 1000
            screen("Left", x: 0, y: 0),            // top 1000, minX 0 (leftmost)
        ]
        XCTAssertEqual(DisplayChoice.index(named: "", in: screens), 1)
    }

    func test_duplicateNames_firstMatchWins() {
        let screens = [
            screen("DUP", x: 0, y: 0),             // 1000 (first match)
            screen("DUP", x: 0, y: 1000),          // 2000 (topmost)
        ]
        XCTAssertEqual(DisplayChoice.index(named: "DUP", in: screens), 0)
    }

    func test_emptyScreenList_returnsNil() {
        XCTAssertNil(DisplayChoice.index(named: "", in: []))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift test --filter DisplayChoiceTests`
Expected: FAIL — compile error, `cannot find 'DisplayChoice' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Translator/Translator/Support/DisplayChoice.swift`:

```swift
import CoreGraphics

/// Pure rule for choosing which display the floating subtitle overlay uses.
/// Kept free of AppKit so it is unit-testable without a real screen;
/// `SubtitlePanel` adapts `NSScreen` to `DisplayChoice.Screen`.
enum DisplayChoice {

    /// A connected display reduced to the fields the rule needs.
    struct Screen: Equatable {
        let name: String
        let frame: CGRect
    }

    /// Index into `screens` of the target display: the connected screen whose
    /// `name` equals `name` (first match), else the physically-topmost screen
    /// (highest top edge `frame.maxY`; smallest `frame.minX` on a tie).
    /// Returns nil only when `screens` is empty.
    static func index(named name: String, in screens: [Screen]) -> Int? {
        if !name.isEmpty,
           let match = screens.firstIndex(where: { $0.name == name }) {
            return match
        }
        return topmostIndex(in: screens)
    }

    private static func topmostIndex(in screens: [Screen]) -> Int? {
        guard !screens.isEmpty else { return nil }
        return screens.indices.max {
            (screens[$0].frame.maxY, -screens[$0].frame.minX)
                < (screens[$1].frame.maxY, -screens[$1].frame.minX)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift test --filter DisplayChoiceTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Translator/Translator/Support/DisplayChoice.swift Translator/Tests/TranslatorTests/DisplayChoiceTests.swift
git commit -m "$(cat <<'EOF'
feat(subtitles): pure display-selection rule

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add `subtitleDisplayName` setting

**Files:**
- Modify: `Translator/Translator/AppSettings.swift`

(No unit test: `AppSettings` is `UserDefaults`-backed and untested in this repo, matching its siblings. Verified by build + Task 5 manual check.)

- [ ] **Step 1: Add the stored property**

In `Translator/Translator/AppSettings.swift`, immediately after the `subtitleShowEnglish` property block (ends around line 77, before the `glossary` doc comment), insert:

```swift
    /// `localizedName` of the display the subtitle panel should use.
    /// Empty string = Automatic (topmost); falls back to topmost when the
    /// named display isn't connected.
    var subtitleDisplayName: String {
        didSet { UserDefaults.standard.set(subtitleDisplayName, forKey: "subtitleDisplayName") }
    }
```

- [ ] **Step 2: Register the default**

In the `defaults.register(defaults: [...])` dictionary in `init`, after the `"subtitleShowEnglish": true,` line, add:

```swift
            "subtitleDisplayName": "",
```

- [ ] **Step 3: Load it in `init`**

After the `self.subtitleShowEnglish = defaults.bool(forKey: "subtitleShowEnglish")` line, add:

```swift
        self.subtitleDisplayName = defaults.string(forKey: "subtitleDisplayName") ?? ""
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift build`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Translator/Translator/AppSettings.swift
git commit -m "$(cat <<'EOF'
feat(subtitles): persist chosen subtitle display name

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Resolve the target screen in `SubtitlePanel`

**Files:**
- Modify: `Translator/Translator/Views/SubtitlePanel.swift`

- [ ] **Step 1: Make `applyPosition()` name-aware**

Replace the body of `applyPosition()` (lines ~34-37) so it passes the chosen name:

```swift
    func applyPosition() {
        let target = Self.frame(displayName: settings.subtitleDisplayName)
        if frame != target { setFrame(target, display: true, animate: false) }
    }
```

- [ ] **Step 2: Replace `frame()` and `topmostScreen` with a name-aware resolver**

Replace the entire static `frame()` method AND the static `topmostScreen` computed property (lines ~46-65) with:

```swift
    private static func frame(displayName: String) -> NSRect {
        let screen = targetScreen(displayName: displayName).visibleFrame
        let width: CGFloat = min(900, screen.width * 0.7)
        let topInset: CGFloat = 8
        let bottomInset: CGFloat = 60
        return NSRect(
            x: screen.midX - width / 2,
            y: screen.minY + bottomInset,
            width: width,
            height: screen.height - topInset - bottomInset)
    }

    /// The display the captions should use: the connected screen matching
    /// `displayName`, else the physically-topmost. The selection rule lives in
    /// the unit-tested `DisplayChoice`; `NSScreen.main`/`first` only guard the
    /// impossible empty-screen case.
    private static func targetScreen(displayName: String) -> NSScreen {
        let screens = NSScreen.screens
        let mapped = screens.map {
            DisplayChoice.Screen(name: $0.localizedName, frame: $0.frame)
        }
        if let idx = DisplayChoice.index(named: displayName, in: mapped) {
            return screens[idx]
        }
        return NSScreen.main ?? screens.first!
    }
```

- [ ] **Step 3: Update the initializer's frame call**

In `init`, change the `super.init` `contentRect:` argument from `Self.frame()` to:

```swift
            contentRect: Self.frame(displayName: settings.subtitleDisplayName),
```

(The `settings` here is the init parameter, available before `super.init`.)

- [ ] **Step 4: Build to verify it compiles**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift build`
Expected: Build succeeds, no reference to the removed `topmostScreen`.

- [ ] **Step 5: Commit**

```bash
git add Translator/Translator/Views/SubtitlePanel.swift
git commit -m "$(cat <<'EOF'
feat(subtitles): position overlay on the chosen display

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: "Subtitle Display" menu-bar submenu

**Files:**
- Modify: `Translator/Translator/StatusItemController.swift`

- [ ] **Step 1: Add the submenu property**

After the `private let sourceMenu = NSMenu(title: "Audio Source")` line (~line 18), add:

```swift
    private let subtitleDisplayMenu = NSMenu(title: "Subtitle Display")
```

- [ ] **Step 2: Add the submenu item in `buildMenu()`**

In `buildMenu()`, immediately after the `subtitleItem` is added (`menu.addItem(subtitleItem)`, ~line 66), add:

```swift
        let subtitleDisplayItem = NSMenuItem(title: "Subtitle Display", action: nil, keyEquivalent: "")
        subtitleDisplayMenu.delegate = self
        subtitleDisplayItem.submenu = subtitleDisplayMenu
        menu.addItem(subtitleDisplayItem)
```

- [ ] **Step 3: Rebuild it on open**

In `menuWillOpen(_:)`, extend the `else if` chain (after the `sourceMenu` branch) with:

```swift
        } else if menu === subtitleDisplayMenu {
            rebuildSubtitleDisplayMenu()
        }
```

- [ ] **Step 4: Add the rebuild + action methods**

After `rebuildSourceMenu()` (before `refreshIcon()`), add:

```swift
    private func rebuildSubtitleDisplayMenu() {
        subtitleDisplayMenu.removeAllItems()
        let chosen = settings.subtitleDisplayName

        let auto = NSMenuItem(title: "Automatic (topmost)",
                              action: #selector(pickSubtitleDisplay(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = chosen.isEmpty ? .on : .off
        subtitleDisplayMenu.addItem(auto)
        subtitleDisplayMenu.addItem(.separator())

        let names = NSScreen.screens.map { $0.localizedName }
        for name in names {
            let item = NSMenuItem(title: name,
                                  action: #selector(pickSubtitleDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = (name == chosen) ? .on : .off
            subtitleDisplayMenu.addItem(item)
        }

        // Remembered-but-disconnected choice stays visible (and checked).
        if !chosen.isEmpty, !names.contains(chosen) {
            let missing = NSMenuItem(title: "\(chosen) (not connected)", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            missing.state = .on
            subtitleDisplayMenu.addItem(missing)
        }
    }

    @objc private func pickSubtitleDisplay(_ sender: NSMenuItem) {
        settings.subtitleDisplayName = (sender.representedObject as? String) ?? ""
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift build`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Translator/Translator/StatusItemController.swift
git commit -m "$(cat <<'EOF'
feat(subtitles): subtitle display picker in menu-bar menu

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: "Display" picker in Settings

**Files:**
- Modify: `Translator/Translator/Views/PreferencesView.swift`

- [ ] **Step 1: Import AppKit for `NSScreen`**

At the top of `Translator/Translator/Views/PreferencesView.swift`, change the import block from `import SwiftUI` to:

```swift
import AppKit
import SwiftUI
```

- [ ] **Step 2: Add the Display picker**

In the subtitle settings `VStack` (the one starting around line 63, holding the `Position` picker), immediately after the `Position` segmented `Picker` block (after its `.pickerStyle(.segmented)` line, ~line 68), insert:

```swift
                        Picker("Display", selection: $settings.subtitleDisplayName) {
                            Text("Automatic (topmost)").tag("")
                            ForEach(NSScreen.screens, id: \.self) { screen in
                                Text(screen.localizedName).tag(screen.localizedName)
                            }
                            // Keep a remembered-but-disconnected choice selectable.
                            if !settings.subtitleDisplayName.isEmpty,
                               !NSScreen.screens.contains(where: { $0.localizedName == settings.subtitleDisplayName }) {
                                Text("\(settings.subtitleDisplayName) (not connected)")
                                    .tag(settings.subtitleDisplayName)
                            }
                        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Translator/Translator/Views/PreferencesView.swift
git commit -m "$(cat <<'EOF'
feat(subtitles): subtitle display picker in Settings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `cd Translator && DEVELOPER_DIR=/Applications/Xcode.app swift test`
Expected: All tests pass, including `DisplayChoiceTests` (6) and the existing `PipelineTests`.

- [ ] **Step 2: Build the app bundle**

Run: `cd Translator && bash Scripts/make-app.sh Release`
Expected: `build/Maldari.app` produced, signing succeeds.

- [ ] **Step 3: Manual check (requires two displays)**

1. Launch `build/Maldari.app`, enable **Subtitle Mode**.
2. Menu bar → **Subtitle Display** → confirm `Automatic (topmost)` is checked and each connected display is listed.
3. Pick the non-topmost display → captions move there within ~0.25s.
4. Open **Settings → General** → confirm the **Display** picker reflects the same choice.
5. Disconnect the chosen display → captions fall back to topmost; the menu shows `<name> (not connected)`.
6. Reconnect it → captions snap back to that display.

Single-display machines: confirm the picker shows `Automatic (topmost)` + the one display, and selecting either keeps captions on it.

---

## Self-Review

**Spec coverage:**
- Setting `subtitleDisplayName` (empty = Automatic) → Task 2. ✓
- Name-match-else-topmost selection, pure & testable → Task 1 (`DisplayChoice`) + Task 3 (adapter). ✓
- Re-homing via existing 0.25s poll, no new wiring → Task 3 (reuses `applyPosition`); confirmed in Task 6 manual steps 3/5/6. ✓
- Menu submenu with Automatic + displays + "(not connected)" row → Task 4. ✓
- Settings picker with same options → Task 5. ✓
- `DisplayChoiceTests` (name match, missing, empty, tie→leftmost, duplicates, empty list) → Task 1. ✓
- Known limitation (duplicate names → first match) → covered by `test_duplicateNames_firstMatchWins`. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `DisplayChoice.Screen(name:frame:)` and `DisplayChoice.index(named:in:)` are used identically in Task 1 (def/tests) and Task 3 (adapter). `subtitleDisplayName: String` is referenced consistently in Tasks 2–5. `pickSubtitleDisplay(_:)` selector matches its `@objc` definition. ✓
