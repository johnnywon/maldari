# Native macOS Real-Time Korean Translator App — Build Spec

## Overview
Build a native macOS app in Swift/SwiftUI that captures audio from any running app, transcribes Korean speech in real-time, translates it to English via Claude API, and displays it in a floating translucent panel. Transcripts auto-save locally and sync to Google Drive.

## Design Reference
The attached `translation-app.jsx` is the UI mockup. Match its visual design exactly. Key design elements:
- Cyberpunk aesthetic: near-black frosted glass, lime (#BBFF00) and cyan (#5CE0D8) two-color accent system
- Monospace font (SF Mono) for system chrome, SF Pro Display for transcript content
- Scanline texture overlay (subtle repeating gradient)
- Corner accent marks on the window frame (small L-shaped lime lines at each corner)
- Top gradient accent bar: lime-to-cyan, 2px height
- Bottom gradient accent bar: same, 1px height, lower opacity

## Window
- `NSPanel` subclass, `styleMask: [.borderless, .nonactivatingPanel]`, `level: .floating`
- `NSVisualEffectView` with `.behindWindow` blending and `.dark` appearance for real frosted glass
- Always-on-top, draggable by the top header area
- Width: ~560px, resizable vertically
- Rounded corners: 8px via `panel.appearance` and masking

## Layout (top to bottom)

### Header bar (single row, 46px height, slightly darker frosted glass)
All controls in one horizontal bar separated by thin vertical borders (0.5px, lime at 5% opacity):

1. **Audio source picker** (left section): Mic icon + source name in lime monospace. Clicking opens a dropdown listing available audio sources from ScreenCaptureKit. Dropdown has same frosted glass background.
2. **LIVE tab** and **TRANSCRIPTS tab**: Monospace 10px, lime when active with 1.5px bottom border, dim when inactive. Switches the content area.
3. **Flexible spacer**
4. **Line count indicator** (only visible during live mode when listening): Small lime dot with count
5. **Listen toggle button** (right section, separated by vertical border): 34x34px. Lime background with animated equalizer bars when active. Dark with muted mic icon when paused. Pulses with subtle glow animation when active.

### Content area (fills remaining space)

**Live mode:**
- Scrolling transcript area, auto-scrolls to bottom on new lines
- Each entry shows:
  - Korean text: 18px, SF Pro Display, cyan (#5CE0D8) at 85% opacity
  - English translation: 20px, SF Pro Display, white (#f2f3f6)
  - Timestamp: bottom-right aligned, 11px monospace, lime at 35% opacity
  - Thin gradient separator line between entries (lime at 4% opacity center, transparent edges)
- "AWAITING SIGNAL..." state with animated cyan bars when listening but no speech detected
- Animated three-dot cyan indicator when waiting for next utterance
- New lines fade-in from below (0.35s ease-out)

**Transcripts mode:**
- Scrolling list of saved sessions
- Each row shows:
  - Session label: 16px, SF Pro Display, medium weight, white
  - Duration badge: lime pill, 9px monospace, dark text on lime background
  - Date line: "2026 March 27, Thursday // 14:15 // 28 LINES" in 11.5px monospace
  - Date and time in rgba(242,243,246,.7), separators in lime at 14% opacity, line count in cyan at 55% opacity
  - Google Drive icon button: 34x34px, right-aligned, cyan-tinted border, opens the transcript in Google Drive
- Rows highlight subtly on hover (lime at 1.5% opacity)

## Audio Pipeline

### ScreenCaptureKit audio capture
- On launch, enumerate available audio sources using `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)`
- List running applications that produce audio
- Also include system microphone inputs
- User selects source from the dropdown
- Create `SCStream` with `SCAudioConfiguration` to capture audio from selected app
- Process `CMSampleBuffer` audio frames
- Feed audio buffers to speech recognizer

### Speech-to-text: Apple Speech Framework
- `SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))`
- Use on-device recognition (requires Apple Silicon)
- Stream via `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true`
- Detect sentence boundaries: pause of 1.5+ seconds or Korean sentence-ending particles
- When a complete sentence is detected, send to translation

## Translation: Claude Haiku Streaming API

### API call
- Endpoint: `https://api.anthropic.com/v1/messages`
- Model: `claude-haiku-4-5-20251001`
- Use `URLSession` with async byte streaming for SSE
- API key stored in macOS Keychain

### System prompt (cache this)
```
You are a Korean-to-English translator for live business conversations. Translate the following Korean text to natural, fluent English. Output only the translation with no preamble or explanation. Maintain business and technical terminology accurately. If the input contains domain-specific terms related to advertising technology, retail media, Amazon Marketing Cloud, or startup operations, preserve them precisely. Do not add quotation marks around the translation.
```

### Sentence batching
- Wait for sentence boundary before sending to API
- This reduces API calls and improves translation quality
- Display partial Korean text immediately, show English once translation streams back

## Storage

### Local: SwiftData + markdown files
- SwiftData model for transcript metadata: id, date, title, duration, lineCount, driveFileId, driveUrl
- Transcript content saves as markdown files in `~/Documents/Translator/`
- Filename format: `2026-03-27_141500_pulsead-product-sync.md`
- Markdown format:
```markdown
---
date: 2026-03-27T14:15:00
duration: 34 min
source: Zoom
lines: 28
---

14:15:03
오늘 미팅에서 AMC 파이프라인 데모를 확정해야 합니다
We need to finalize the AMC pipeline demo in today's meeting

14:15:18
한국 쪽 클라이언트 세 곳이 이번 분기에 계약 마무리 단계에 있습니다
Three clients on the Korea side are in the final stages of closing contracts this quarter
```

### Google Drive: OAuth2 + background upload
- OAuth2 flow: open system browser for Google sign-in, receive auth code via localhost redirect
- Store refresh token in Keychain
- Auto-upload completed transcripts to a "Translator" folder in Drive
- Use `URLSessionConfiguration.background` for uploads
- Store returned Drive file ID and construct direct URL for "Open in Drive" button
- Show sync status in transcript list (cyan dot = synced)

## Entitlements & Permissions
- `com.apple.security.screen-recording` — required for ScreenCaptureKit audio capture
- `NSMicrophoneUsageDescription` — for microphone fallback
- `NSSpeechRecognitionUsageDescription` — for Apple Speech
- Network access for Claude API and Google Drive API
- Keychain access for API key and OAuth token storage

## Project Structure
```
Translator/
├── Package.swift or Translator.xcodeproj
├── Translator/
│   ├── TranslatorApp.swift              // @main, app lifecycle, menu bar
│   ├── TranslatorPanel.swift            // NSPanel + NSVisualEffectView
│   ├── Theme.swift                      // Colors, fonts, design constants
│   ├── Views/
│   │   ├── HeaderBar.swift              // Combined controls bar
│   │   ├── AudioSourcePicker.swift      // Dropdown for audio sources
│   │   ├── LiveTranscriptView.swift     // Streaming transcript display
│   │   ├── TranscriptListView.swift     // Saved sessions list
│   │   └── ListenToggle.swift           // Animated mic button
│   ├── Audio/
│   │   ├── AudioCaptureManager.swift    // ScreenCaptureKit wrapper
│   │   └── SpeechManager.swift          // SFSpeechRecognizer streaming
│   ├── Translation/
│   │   └── ClaudeTranslator.swift       // Streaming API client
│   ├── Storage/
│   │   ├── TranscriptStore.swift        // SwiftData + file management
│   │   └── DriveSync.swift              // Google Drive OAuth2 + upload
│   └── Models/
│       ├── TranscriptLine.swift         // Single ko/en pair with timestamp
│       └── TranscriptSession.swift      // Full session metadata
├── Translator/Info.plist
└── Translator/Translator.entitlements
```

## Key Implementation Notes
- Use `@Observable` and `@State` for reactive UI updates
- All audio processing on a dedicated `DispatchQueue` (not main thread)
- Translation API calls via Swift async/await with `TaskGroup` for concurrent sentence translations
- ScreenCaptureKit requires the user to grant screen recording permission on first launch
- The app should also register as a menu bar utility (small icon in menu bar for quick access)
- Support Cmd+Q to quit, Cmd+W to hide panel, spacebar to toggle listening
- Dark mode only (hardcoded, no light mode)

## API Keys Needed
The user will need to provide:
1. Anthropic API key (for Claude Haiku translations)
2. Google OAuth2 client ID and secret (for Drive sync)

On first launch, prompt for the Anthropic API key and store in Keychain. Google OAuth triggers when user first clicks "Open in Drive" or enables sync.

## Build Target
- macOS 14.0+ (Sonoma minimum for latest ScreenCaptureKit APIs)
- Apple Silicon required (for on-device speech recognition)
- Swift 5.9+
- No third-party dependencies — use only Apple frameworks + raw HTTP to Anthropic and Google APIs
