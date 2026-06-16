import AppKit
import SwiftUI

/// Custom NSPanel subclass for the floating translator window
final class TranslatorPanel: NSPanel {

    init(contentView: NSView) {
        super.init(
            // No `.nonactivatingPanel`: that flag kept the overlay from
            // stealing focus, but it also meant clicking/switching to the
            // window never made Maldari the active app — so the macOS menu bar
            // never showed "Maldari". Activating normally is worth the small
            // focus cost; it still floats via the `.floating` level below.
            contentRect: NSRect(x: 0, y: 0, width: Theme.windowWidth, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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
        // Minimum size: well below the default so the window can shrink to a
        // compact strip. The 380 floor keeps the centered header island from
        // crowding the two side zones; 140 tall is header + a couple of rows.
        self.minSize = NSSize(width: 380, height: 140)

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

    // Allow the panel to receive key events and act as the app's main window
    // (NSPanel returns false for canBecomeMain by default, which keeps the app
    // from fully activating and showing its menu bar).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Support keyboard shortcuts beyond what the menu bar provides
    override func keyDown(with event: NSEvent) {
        // Spacebar toggles listening (handled by SwiftUI responder chain)
        super.keyDown(with: event)
    }
}
