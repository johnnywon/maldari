import AppKit
import SwiftUI

/// Borderless always-on-top panel showing the last two English lines —
/// "subtitle mode", toggled from the menu bar or Settings.
final class SubtitlePanel: NSPanel {
    init(pipeline: PipelineController) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = min(900, screen.width * 0.7)
        let rect = NSRect(
            x: screen.midX - width / 2,
            y: screen.minY + 60,
            width: width,
            height: 110)

        super.init(
            contentRect: rect,
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
        contentView = NSHostingView(rootView: SubtitleContent(pipeline: pipeline))
    }
}

private struct SubtitleContent: View {
    @Bindable var pipeline: PipelineController

    private var lines: [String] {
        pipeline.store.utterances
            .filter { !$0.english.isEmpty }
            .suffix(2)
            .map { ($0.speaker.map { "\($0.label): " } ?? "") + $0.english }
    }

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Theme.sans(size: 20, weight: .medium))
                    .foregroundColor(.white)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: lines)
    }
}
