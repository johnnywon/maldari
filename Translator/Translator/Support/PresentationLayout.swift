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
/// (`AppSettings.presentationFontScale`, 0.6...3.2), the measured geometry, or
/// the live text itself, so the view can call them on every layout pass. The
/// view holds the state the rules are applied *to* — the current fit, the rows
/// already yielded, the latched language — and these functions decide only what
/// the next value of it should be.
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

    // MARK: - Room

    /// The vertical room the live row has to live within — or the fact that
    /// nothing has been measured yet.
    ///
    /// **Those are two different states and they must not share a sentinel.**
    /// These rules used to take a bare height and read `<= 0` as "the window has
    /// not been laid out yet", which a first layout pass really does report. But
    /// when history has consumed the whole feed, the room left for the live row
    /// genuinely computes to zero or less — and that was then read as missing
    /// information: nothing overflowed, `shouldYieldHistory` was never
    /// consulted, history never yielded a row, and the live row stayed clipped
    /// with no way out for the rest of the sentence. Giving the absence of a
    /// measurement its own case lets a measured non-positive room mean what it
    /// says (maximum pressure) while the first pass still leaves the fit alone.
    enum Room: Equatable {
        /// No layout pass has reported the feed's geometry yet. Never pressure:
        /// shrinking on it would ratchet the text down to `minFit` before a
        /// single frame is drawn.
        case unmeasured

        /// A real measurement. May be zero or negative, which is not an error —
        /// it is history having taken everything, and it is the strongest
        /// pressure there is.
        case measured(CGFloat)

        /// The measured height, or nil when nothing has been measured yet.
        var measuredHeight: CGFloat? {
            guard case .measured(let height) = self else { return nil }
            return height
        }

        /// A measurement arrived and it left the live row nothing at all.
        /// `.unmeasured` is deliberately *not* exhausted.
        var isExhausted: Bool {
            guard let height = measuredHeight else { return false }
            return height <= 0
        }
    }

    // MARK: - Escalation

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
    ///   - room: Room available to it. `.unmeasured` is never pressure;
    ///     a measured room of zero or less is maximum pressure — see `Room`.
    ///   - historyRows: History rows the feed is drawing right now.
    static func shouldYieldHistory(contentHeight: CGFloat, room: Room,
                                   historyRows: Int) -> Bool {
        guard historyRows > 0 else { return false }
        guard let height = room.measuredHeight else { return false }
        // Zero or less is not "it fits": history has taken the whole feed and
        // the live row is already clipped. Escalate on the room alone, without
        // consulting `contentHeight`, because a row given no height can report
        // no overflow — waiting for one is exactly how this used to deadlock.
        guard height > 0 else { return true }
        return contentHeight > height
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

    /// The most steps one fit can ever take: 1.0 down to `minFit`, one
    /// `fitStep` at a time.
    ///
    /// Stated as a rule rather than left implicit because it *is* the
    /// termination bound the view relies on. The fit only ever falls (see
    /// `fittedScale`), so this is also the greatest number of re-renders a
    /// single (utterance, room) pair can cost for fitting reasons.
    static var maxFitSteps: Int {
        Int(((1.0 - minFit) / fitStep).rounded(.up))
    }

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
    /// **Monotone by construction, and that is the whole termination argument.**
    /// This is the only rule that moves the fit, it only ever moves it *down*,
    /// and `maxFitSteps` bounds how far down it can go — so for one (utterance,
    /// room) pair the view's passes form a decreasing sequence on a finite
    /// lattice and reach a fixed point after at most `maxFitSteps` changes. No
    /// tuning is involved and no cycle is expressible.
    ///
    /// There used to be a matching `grownScale` that stepped back up whenever
    /// the content fell below 88% of the room, and it could not be made to
    /// terminate. The 12% hysteresis band was expressed in *height*, but what
    /// actually changes when the scale changes is the number of wrapped
    /// *lines*, and one line is a far larger fraction of a row than 12%: a row
    /// that wraps to three lines at `s` and two at `s - fitStep` overflowed,
    /// shrank, landed far below the band, grew straight back to `s`, and
    /// overflowed again — forever, re-rendering the caption on every pass, which
    /// on a projector is a permanent CPU burn and a visibly twitching line.
    /// Widening the band is not a fix (no fixed percentage exceeds one line's
    /// height at every scale, and a caption held 30% smaller than it needs to be
    /// is its own defect), so growth is no longer a step at all: the fit returns
    /// to 1.0 only when an input genuinely changes — a new utterance, a manual
    /// scale change, a resize — via `PresentationView.resetFit`. Shrink and grow
    /// cannot alternate when there is no grow.
    ///
    /// - Parameters:
    ///   - contentHeight: Measured height of the live row at `current`.
    ///   - room: Height available for the live row. Values `<= 0` mean the
    ///     window has not been laid out yet. Callers that can tell that state
    ///     from "no room left" should use the `Room` overload, which is the one
    ///     the view calls.
    ///   - current: Scale in force for this pass.
    /// - Returns: The scale to use for the next pass, never below `minFit` and
    ///   never above `current`.
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

    /// `fittedScale` against a `Room` — the entry point the view uses, and the
    /// one that can tell "not laid out yet" from "no room left".
    ///
    /// A measured room of zero or less shrinks a step without consulting
    /// `contentHeight`: nothing can be *measured* to overflow a row that was
    /// given no height, and by the time the view asks this, history has already
    /// yielded every row it had (see `shouldYieldHistory`), so the live text is
    /// the only lever left. Shrinking it is still bounded by `minFit`, below
    /// which an overlong sentence is allowed to clip rather than become
    /// illegible for the whole room.
    ///
    /// - Returns: The scale to use for the next pass, never below `minFit` and
    ///   never above `current`.
    static func fittedScale(contentHeight: CGFloat, in room: Room,
                            current: Double) -> Double {
        guard let height = room.measuredHeight else { return current }
        guard height > 0 else { return max(minFit, current - fitStep) }
        return fittedScale(contentHeight: contentHeight, room: height,
                           current: current)
    }

    // MARK: - Language latch

    /// How many letter-bearing characters a *hypothesis* must carry before its
    /// detected language may be latched for the rest of the utterance.
    ///
    /// The latch exists because a mid-sentence flip swaps the live row's two
    /// columns and its accent in front of the room. But latching the *first*
    /// detection made the common case worse than no latch at all: the first
    /// delta is the shortest and least reliable text there will ever be, and
    /// `ScriptDetector` is a simple majority of letter-bearing scalars, so two
    /// or three characters of a romanized product name, an acronym, or a
    /// sentence opening with a number decide the whole utterance wrongly and
    /// then hold it. Reading the detection live at least self-corrected as the
    /// text grew.
    ///
    /// **Why seven.** A wrong answer needs more than half the letters to come
    /// from the wrong script, so at a threshold of N an opening romanization of
    /// L letters is outvoted once N - L Hangul syllables have arrived. Seven
    /// puts the worst case that actually occurs — a three-letter acronym
    /// ("KTX", "API") — at four Hangul against three Latin, which detects
    /// correctly; and Korean is syllable-dense enough that seven letters is two
    /// or three words, so the latch still lands within the opening deltas and
    /// the flicker it was added for stays fixed. Digits count for nothing here
    /// or in `ScriptDetector`, so "2024년부터" is judged on its Hangul alone.
    static let languageLatchLetters = 7

    /// How many of `text`'s scalars are letter-bearing — the evidence
    /// `ScriptDetector` actually judges on — counted no further than `limit`.
    ///
    /// Asks `ScriptDetector` itself, one scalar at a time, rather than
    /// reproducing its Hangul and Latin ranges here: `hangulFraction` returns
    /// nil exactly when there is nothing to judge, so a scalar is
    /// letter-bearing precisely when it has a fraction. A private copy of the
    /// ranges would be free to drift, and would then count characters the
    /// detector ignores — the opposite of measuring the detector's confidence.
    ///
    /// Capped rather than total for two reasons: the caller only ever compares
    /// it against a threshold, and a capped count *stops changing* once the
    /// threshold is reached, which keeps the view's `onChange` from waking on
    /// every later delta of a long sentence.
    static func letterCount(_ text: String, cappedAt limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        var count = 0
        for scalar in text.unicodeScalars {
            guard ScriptDetector.hangulFraction(String(scalar)) != nil else { continue }
            count += 1
            if count >= limit { return count }
        }
        return count
    }

    /// Whether a detected language is trustworthy enough to hold for the rest of
    /// the utterance.
    ///
    /// Anything past `.hypothesis` is authoritative — the arbiter (or a pin)
    /// decided it — and is adopted and held whatever it says. A hypothesis is
    /// trusted only once it carries `languageLatchLetters` letters; below that
    /// the view keeps re-adopting the current detection, so a wrong opening
    /// corrects itself as the text grows. A hypothesis that never reaches the
    /// threshold never latches, which is the right answer rather than a gap:
    /// there was never enough evidence to freeze.
    ///
    /// - Parameters:
    ///   - letterCount: Letter-bearing characters in the source text so far.
    ///     May be capped at the threshold; only the comparison matters.
    ///   - isHypothesis: Whether the source transcript is still mutating.
    static func canLatchLanguage(letterCount: Int, isHypothesis: Bool) -> Bool {
        guard isHypothesis else { return true }
        return letterCount >= languageLatchLetters
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
