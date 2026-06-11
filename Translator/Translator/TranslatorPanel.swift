import AppKit
import SwiftUI

/// Custom NSPanel subclass for the floating translator window
final class TranslatorPanel: NSPanel {

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Theme.windowWidth, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.title = "Maldari"
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        // Drag only from the (invisible) titlebar area at the top of the window.
        // Having the entire window body act as a drag handle swallows resize
        // cursors at the bottom-left and top-right corners — disabling it frees
        // all four corners for native macOS window resize.
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.animationBehavior = .utilityWindow
        self.hidesOnDeactivate = false
        self.appearance = NSAppearance(named: .darkAqua)
        // Lock the default dimensions as the minimum — users can drag the
        // bottom corners to make the window wider/taller, never smaller.
        self.minSize = NSSize(width: Theme.windowWidth, height: 620)

        // Allow the panel to become key for keyboard events
        self.becomesKeyOnlyIfNeeded = true

        // Set up the visual effect view for frosted glass
        let visualEffect = NSVisualEffectView(frame: self.contentRect(forFrameRect: self.frame))
        visualEffect.blendingMode = .behindWindow
        visualEffect.material = .hudWindow
        visualEffect.appearance = NSAppearance(named: .darkAqua)
        visualEffect.state = .active

        // Add the SwiftUI content on top
        contentView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        self.contentView = visualEffect

        // Position on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - Theme.windowWidth - 40
            let y = screenFrame.midY - 310
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // Allow the panel to receive key events
    override var canBecomeKey: Bool { true }

    // Support keyboard shortcuts beyond what the menu bar provides
    override func keyDown(with event: NSEvent) {
        // Spacebar toggles listening (handled by SwiftUI responder chain)
        super.keyDown(with: event)
    }
}
