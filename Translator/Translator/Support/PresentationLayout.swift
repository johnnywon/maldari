import CoreGraphics
import Foundation

/// Pure layout rules for the Presentation window, ported from the approved
/// HTML design prototype.
///
/// The Presentation window is what an audience reads on a projector, so its
/// geometry is decided by rules rather than by SwiftUI's own sizing: the live
/// row must never be clipped mid-sentence, and history must never push it off
/// screen. Keeping those rules here — free of SwiftUI, AppKit and
/// `AppSettings` — means the awkward cases (a zero-height window on the first
/// layout pass, a single history row, an empty transcript) are unit-testable
/// without standing up a window on a real display.
///
/// All four rules are stateless functions of the user's font scale
/// (`AppSettings.presentationFontScale`, 0.6...3.2) and the measured
/// geometry, so the view can call them on every layout pass.
enum PresentationLayout {

    /// How many history rows to show above the live row.
    ///
    /// History shrinks as type grows. At projector sizes two lines of the
    /// current sentence already fill most of the frame, so keeping three
    /// history rows would either clip the live row or force `fittedScale` to
    /// shrink the very text the user just enlarged. Dropping history instead
    /// honours the user's scale choice: the live sentence always wins the
    /// available room.
    ///
    /// Thresholds are exclusive — a scale of exactly 2.2 still gets one
    /// history row, exactly 1.8 gets two, exactly 1.2 gets three — so the
    /// discrete steps of `AppSettings.presentationScaleStep` land on the
    /// generous side of each boundary.
    static func historyDepth(forScale scale: Double) -> Int {
        if scale > 2.2 { return 0 }
        if scale > 1.8 { return 1 }
        if scale > 1.2 { return 2 }
        return 3
    }

    /// Lower bound for the fitted scale. Below this the text is too small to
    /// read from the back of a room, so an overlong sentence is allowed to
    /// clip rather than becoming illegible for everybody.
    static let minFit: Double = 0.6

    /// One shrink step per layout pass. Small enough that the step is read as
    /// the text settling rather than as a jump.
    static let fitStep: Double = 0.06

    /// Shrink factor applied on top of the user's scale so the live row never
    /// overflows its reading area.
    ///
    /// Deliberately takes *one* step per call instead of solving for the
    /// fitting scale directly. The view calls this every layout pass with the
    /// height SwiftUI just measured, so successive passes converge on the
    /// largest scale that fits. Computing a target in one shot would have to
    /// guess how height responds to scale (it is not linear — reflowing text
    /// changes the line count), and guessing wrong shows up as the whole
    /// sentence snapping to a wrong size and back.
    ///
    /// Never grows the scale back: when the content already fits, `current`
    /// is returned untouched. Growth belongs to the user's own scale control;
    /// re-growing here would oscillate against the shrink step, one step in
    /// each direction, forever.
    ///
    /// - Parameters:
    ///   - contentHeight: Measured height of the live row at `current`.
    ///   - room: Height available for the live row. Values `<= 0` mean the
    ///     window has not been laid out yet.
    ///   - current: Scale in force for this pass.
    /// - Returns: The scale to use for the next pass, never below `minFit`.
    static func fittedScale(contentHeight: CGFloat, room: CGFloat,
                            current: Double) -> Double {
        // A zero (or negative) room is the first layout pass reporting "I do
        // not know my size yet", not "nothing fits". Shrinking on it would
        // ratchet the text down to minFit before a single frame is drawn, and
        // nothing here ever grows it back, so the window would open tiny and
        // stay tiny. Treat unknown geometry as "leave the scale alone".
        guard room > 0 else { return current }
        guard contentHeight > room else { return current }
        return max(minFit, current - fitStep)
    }

    /// Opacity for history row `index` of `count`, oldest first.
    ///
    /// A linear ramp from 0.30 (oldest) to 0.58 (newest) puts the audience's
    /// eye on the newest history row while older lines stay readable as
    /// context. The live row is rendered at full opacity by the view, so the
    /// ramp deliberately stops well short of 1.0 — the brightness gap is what
    /// marks which line is currently being spoken.
    ///
    /// The divisor is clamped to at least 1, so a single history row (and the
    /// degenerate `count == 0`) yields the dimmest value instead of dividing
    /// by zero. A lone row has no ramp to sit on; 0.30 keeps it clearly
    /// subordinate to the live row.
    static func historyOpacity(index: Int, count: Int) -> Double {
        let span = Double(max(1, count - 1))
        return 0.30 + 0.28 * Double(index) / span
    }

    /// Base type size in points for a given scale.
    ///
    /// 34pt at scale 1.0 is the prototype's body size. Rounded to whole
    /// points because fractional sizes make successive rows land on different
    /// subpixel baselines, which reads as the block of text shimmering as
    /// rows are added.
    static func fontSize(scale: Double) -> CGFloat {
        CGFloat((34.0 * scale).rounded())
    }
}
