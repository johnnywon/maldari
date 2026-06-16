import AppKit
import SwiftUI

/// Borderless always-on-top panel showing the last two English lines —
/// "subtitle mode", toggled from the menu bar or Settings.
final class SubtitlePanel: NSPanel {
    private let settings: AppSettings

    init(pipeline: PipelineController, settings: AppSettings = .shared) {
        self.settings = settings

        super.init(
            contentRect: Self.frame(),
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

    /// Keep the panel on the topmost screen. Called from the app's settings
    /// poll so it re-homes after a display reconfiguration. The Top/Bottom
    /// position and caption size are handled inside `SubtitleContent` (edge
    /// alignment + font), so the panel frame itself never changes here — no
    /// redraw churn. No-ops when the target frame already matches.
    func applyPosition() {
        let target = Self.frame()
        if frame != target { setFrame(target, display: true, animate: false) }
    }

    /// A centered column spanning the usable screen height, inset 60pt top and
    /// bottom. The panel is transparent and click-through, so the empty area is
    /// invisible — it just gives the captions room to wrap to full height
    /// (anchored to the top or bottom edge by `SubtitleContent`) without the
    /// window clipping them.
    private static func frame() -> NSRect {
        let screen = topmostScreen.visibleFrame
        let width: CGFloat = min(900, screen.width * 0.7)
        let margin: CGFloat = 60
        return NSRect(
            x: screen.midX - width / 2,
            y: screen.minY + margin,
            width: width,
            height: screen.height - margin * 2)
    }

    /// The physically-topmost display (highest top edge; leftmost on a tie).
    /// Deterministic — unlike `NSScreen.main`, which follows keyboard focus and
    /// makes the captions wander to whatever screen was last clicked.
    private static var topmostScreen: NSScreen {
        NSScreen.screens.max {
            ($0.frame.maxY, -$0.frame.minX) < ($1.frame.maxY, -$1.frame.minX)
        } ?? NSScreen.main ?? NSScreen.screens.first!
    }
}

private struct SubtitleContent: View {
    @Bindable var pipeline: PipelineController
    @Bindable var settings: AppSettings

    private var lines: [String] {
        pipeline.store.utterances
            .filter { !$0.english.isEmpty }
            .suffix(2)
            .map(\.english)
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Theme.sans(size: 20 * settings.subtitleFontScale, weight: .medium))
                    .foregroundColor(Color(hex: UInt(settings.subtitleColorHex & 0xFFFFFF)))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.72))
                    )
                    .shadow(radius: 3)
            }
        }
        // Hug the screen edge the panel is pinned to: top-aligned up top,
        // bottom-aligned down low.
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: settings.subtitleAtTop ? .top : .bottom)
        .animation(.easeOut(duration: 0.15), value: lines)
    }
}
