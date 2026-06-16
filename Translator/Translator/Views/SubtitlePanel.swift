import AppKit
import SwiftUI

/// Borderless always-on-top panel showing the last two English lines —
/// "subtitle mode", toggled from the menu bar or Settings.
final class SubtitlePanel: NSPanel {
    private let settings: AppSettings

    init(pipeline: PipelineController, settings: AppSettings = .shared) {
        self.settings = settings

        super.init(
            contentRect: Self.frame(atTop: settings.subtitleAtTop,
                                    scale: settings.subtitleFontScale),
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

    /// Reposition/resize to match the current position + size settings. Called
    /// from the app's settings poll, so changing either updates the panel live.
    /// No-ops when the target frame already matches to avoid redraw churn.
    func applyPosition() {
        let target = Self.frame(atTop: settings.subtitleAtTop, scale: settings.subtitleFontScale)
        if frame != target { setFrame(target, display: true, animate: false) }
    }

    /// Centered horizontally; pinned 60pt from the chosen screen edge. Height
    /// grows with the caption scale so larger text never clips.
    private static func frame(atTop: Bool, scale: Double) -> NSRect {
        let screen = topmostScreen.visibleFrame
        let width: CGFloat = min(900, screen.width * 0.7)
        let height: CGFloat = 110 * scale
        let margin: CGFloat = 60
        return NSRect(
            x: screen.midX - width / 2,
            y: atTop ? screen.maxY - height - margin : screen.minY + margin,
            width: width,
            height: height)
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
                    .lineLimit(2)
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
