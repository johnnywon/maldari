import AppKit

/// Sets the Dock icon to the Maldari 말 mark (drawn by `MaldariIcon`).
enum AppIcon {
    static func setDockIcon() {
        NSApp.applicationIconImage = MaldariIcon.appIcon(size: 512)
    }
}
