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
