import AppKit
import SwiftUI

/// Borderless always-on-top panel showing the last two English lines —
/// "subtitle mode", toggled from the menu bar or Settings.
final class SubtitlePanel: NSPanel {
    private let settings: AppSettings

    init(pipeline: PipelineController, settings: AppSettings = .shared) {
        self.settings = settings

        super.init(
            contentRect: Self.frame(displayName: settings.subtitleDisplayName),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(
            rootView: SubtitleContent(pipeline: pipeline, settings: settings))
    }

    /// Keep the panel on the chosen screen. Called from the app's settings
    /// poll so it re-homes after a display reconfiguration or when the user
    /// picks a different display. The Top/Bottom position and caption size are
    /// handled inside `SubtitleContent` (edge alignment + font), so the panel
    /// frame itself never changes here — no redraw churn. No-ops when the
    /// target frame already matches.
    func applyPosition() {
        let target = Self.frame(displayName: settings.subtitleDisplayName)
        if frame != target { setFrame(target, display: true, animate: false) }
    }

    /// A centered column spanning the usable screen height. The panel is
    /// transparent and click-through, so the empty area is invisible — it just
    /// gives the captions room to wrap to full height. `SubtitleContent`
    /// anchors them to the top or bottom edge, so each inset governs only the
    /// position that hugs it: a small top inset keeps top captions flush just
    /// under the menu bar; a larger bottom inset keeps bottom captions clear of
    /// the Dock.
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
}

private struct SubtitleContent: View {
    @Bindable var pipeline: PipelineController
    @Bindable var settings: AppSettings

    private struct Entry: Identifiable, Equatable {
        let id: Int
        let korean: String
        let english: String
    }

    /// The last two finalized utterances: Korean always (appears the moment
    /// STT finalizes, ahead of the translation), English when it's arrived.
    private var entries: [Entry] {
        pipeline.store.utterances
            .suffix(2)
            .map { Entry(id: $0.id, korean: $0.korean, english: $0.english) }
    }

    private var englishColor: Color { Color(hex: UInt(settings.subtitleColorHex & 0xFFFFFF)) }
    private var scale: CGFloat { settings.subtitleFontScale }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(entries) { entry in
                let showEnglish = settings.subtitleShowEnglish && !entry.english.isEmpty
                if !entry.korean.isEmpty || showEnglish {
                    VStack(spacing: 3) {
                        if !entry.korean.isEmpty {
                            Text(entry.korean)
                                .font(Theme.sans(size: 17 * scale, weight: .medium))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if showEnglish {
                            Text(entry.english)
                                .font(Theme.sans(size: 20 * scale, weight: .semibold))
                                .foregroundColor(englishColor)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.72))
                    )
                    .shadow(radius: 3)
                }
            }
        }
        // Hug the screen edge the panel is pinned to: top-aligned up top,
        // bottom-aligned down low.
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: settings.subtitleAtTop ? .top : .bottom)
        .animation(.easeOut(duration: 0.15), value: entries)
    }
}
