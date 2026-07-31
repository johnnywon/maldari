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
/// Every rule here is a stateless function of the user's font scale
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
    ///
    /// **`rowsYielded` is why this is not a function of scale alone.** As a
    /// function of scale only, history kept its full-size rows no matter how
    /// badly the live row was overflowing, so a long sentence was answered by
    /// shrinking the *live* text while three settled lines held their space —
    /// the one line the room needs to read ended up smaller than the finished
    /// lines above it, which inverts the whole point of the layout. The view
    /// raises `rowsYielded` under pressure (see `shouldYieldHistory`) so room
    /// is taken from history first and the live row shrinks only once there is
    /// no history left to give.
    ///
    /// - Parameters:
    ///   - scale: The user's font scale.
    ///   - rowsYielded: Rows already surrendered to the live row. Negative
    ///     values are ignored rather than buying extra history.
    static func historyDepth(forScale scale: Double, rowsYielded: Int = 0) -> Int {
        max(0, depth(forScale: scale) - max(0, rowsYielded))
    }

    /// The scale-only part of the depth rule, kept separate so the pressure
    /// term above cannot accidentally rewrite the design's thresholds.
    private static func depth(forScale scale: Double) -> Int {
        if scale > 2.2 { return 0 }
        if scale > 1.8 { return 1 }
        if scale > 1.2 { return 2 }
        return 3
    }

    /// Whether an overflowing live row should claim a history row instead of
    /// shrinking itself — the escalation order that keeps the live row from
    /// ever being set smaller than the history above it.
    ///
    /// Takes the number of history rows *currently drawn*, not the depth: a
    /// depth above the number of utterances that exist draws fewer rows than it
    /// permits, and yielding a row that is not on screen frees no room at all.
    /// Requiring a drawn row is what guarantees each yield makes progress, so
    /// the escalation cannot stall with the live row still clipped.
    ///
    /// - Parameters:
    ///   - contentHeight: Measured height of the live row.
    ///   - room: Height available to it. `<= 0` means "not laid out yet", which
    ///     is never pressure — see `fittedScale`.
    ///   - historyRows: History rows the feed is drawing right now.
    static func shouldYieldHistory(contentHeight: CGFloat, room: CGFloat,
                                   historyRows: Int) -> Bool {
        guard room > 0, historyRows > 0 else { return false }
        return contentHeight > room
    }

    /// How much to raise the yield by so that exactly one *drawn* history row
    /// disappears.
    ///
    /// Not simply 1, because a depth can exceed the number of utterances that
    /// exist: with three rows permitted and one utterance to show, the first
    /// three single-row yields would each drop a row that was never on screen,
    /// freeing nothing. The view re-evaluates the fit off the *measured* room,
    /// so a yield that changes no measurement is a yield that never gets a
    /// second pass — the live row would sit clipped with history still up.
    ///
    /// - Parameters:
    ///   - depth: The depth currently in force (`historyDepth`).
    ///   - drawnRows: How many rows the feed is actually drawing at that depth.
    /// - Returns: An increment of at least 1, sized to cut into the drawn rows.
    static func yieldStep(depth: Int, drawnRows: Int) -> Int {
        max(1, depth - drawnRows + 1)
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
    /// is returned untouched. Growing is `grownScale`'s job, and it is a
    /// separate function precisely because the two must not share a threshold —
    /// a single rule that shrank above `room` and grew below it would trade one
    /// step in each direction forever.
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

    /// Fraction of the room the content must fall *below* before the fit is
    /// allowed to grow. The 12% between this and 1.0 is the hysteresis band
    /// that separates `grownScale` from `fittedScale`: one grow step adds
    /// roughly 6% of height, so growing from inside the band cannot land past
    /// the room and provoke a shrink on the next pass. Without the band the
    /// live row would flip between two sizes on every frame.
    static let growSlack: Double = 0.88

    /// Recover the fit toward 1.0 when the live row has room to spare.
    ///
    /// The counterpart to `fittedScale`, and not optional politeness: nothing
    /// else ever raises the fit, so before this existed one long sentence in a
    /// small window pinned the text at `minFit`, and enlarging the window —
    /// exactly what someone does when the caption is too small — left it pinned
    /// there until the next sentence. On a projector that is a permanently
    /// undersized caption.
    ///
    /// Steps by the same `fitStep` as the shrink so a recovery reads as the
    /// text settling rather than as a jump, and never past 1.0: above that is
    /// the user's own scale control, not ours to touch.
    ///
    /// - Parameters:
    ///   - contentHeight: Measured height of the live row at `current`.
    ///   - room: Height available for the live row. `<= 0` means the window has
    ///     not been laid out yet, which is not evidence of spare room.
    ///   - current: Scale in force for this pass.
    /// - Returns: The scale to use for the next pass, never above 1.0.
    static func grownScale(contentHeight: CGFloat, room: CGFloat,
                           current: Double) -> Double {
        guard room > 0 else { return current }
        guard current < 1.0 else { return current }
        guard Double(contentHeight) < growSlack * Double(room) else { return current }
        return min(1.0, current + fitStep)
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
