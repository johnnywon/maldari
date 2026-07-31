import XCTest
@testable import Translator

final class PresentationLayoutTests: XCTestCase {

    // MARK: - historyDepth

    /// Boundaries are exclusive, so the threshold value itself keeps the more
    /// generous depth. Checked exactly on and just either side of each one.
    func test_historyDepth_boundaries() {
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.19), 3)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.2), 3)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.21), 2)

        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.79), 2)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.8), 2)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.81), 1)

        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 2.19), 1)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 2.2), 1)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 2.21), 0)
    }

    func test_historyDepth_settingsRangeEnds() {
        // 0.6...3.2 is the range AppSettings clamps presentationFontScale to.
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 0.6), 3)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.0), 3)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 3.2), 0)
    }

    /// Bigger type must never buy *more* history rows.
    func test_historyDepth_neverIncreasesWithScale() {
        var previous = PresentationLayout.historyDepth(forScale: 0.6)
        var scale = 0.6
        while scale <= 3.2 {
            let depth = PresentationLayout.historyDepth(forScale: scale)
            XCTAssertLessThanOrEqual(depth, previous, "scale \(scale)")
            previous = depth
            scale += 0.12       // AppSettings.presentationScaleStep
        }
    }

    // MARK: - historyDepth under pressure

    /// The pressure term defaults to nothing, so every scale-only caller and
    /// every scale-only expectation above still holds.
    func test_historyDepth_defaultYieldMatchesScaleOnlyRule() {
        var scale = 0.6
        while scale <= 3.2 {
            XCTAssertEqual(PresentationLayout.historyDepth(forScale: scale),
                           PresentationLayout.historyDepth(forScale: scale,
                                                           rowsYielded: 0),
                           "scale \(scale)")
            scale += 0.12
        }
    }

    func test_historyDepth_eachYieldedRowCostsOneRow() {
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.0,
                                                       rowsYielded: 1), 2)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.0,
                                                       rowsYielded: 2), 1)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.0,
                                                       rowsYielded: 3), 0)
    }

    /// Pressure can empty history but never take it below empty, and it can
    /// never hand *back* rows the scale rule already refused.
    func test_historyDepth_yieldClampsAtZero() {
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.0,
                                                       rowsYielded: 9), 0)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 3.0,
                                                       rowsYielded: 1), 0)
    }

    func test_historyDepth_negativeYieldBuysNoExtraHistory() {
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 1.0,
                                                       rowsYielded: -5), 3)
        XCTAssertEqual(PresentationLayout.historyDepth(forScale: 2.0,
                                                       rowsYielded: -5), 1)
    }

    /// Yielding is bounded by the depth in force, so the escalation always ends.
    func test_historyDepth_yieldingReachesZeroInDepthSteps() {
        var scale = 0.6
        while scale <= 3.2 {
            let base = PresentationLayout.historyDepth(forScale: scale)
            XCTAssertEqual(PresentationLayout.historyDepth(forScale: scale,
                                                           rowsYielded: base), 0,
                           "scale \(scale)")
            scale += 0.12
        }
    }

    // MARK: - shouldYieldHistory

    func test_shouldYieldHistory_overflowWithHistoryDrawn_yields() {
        XCTAssertTrue(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: 600, historyRows: 3))
    }

    /// The invariant this rule exists for: the live row shrinks only once there
    /// is no drawn history left to take room from, so it can never be set
    /// smaller than the settled lines above it.
    func test_shouldYieldHistory_noHistoryDrawn_shrinksInstead() {
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: 600, historyRows: 0))
    }

    func test_shouldYieldHistory_contentFits_doesNotYield() {
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 600, room: 600, historyRows: 3))
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 100, room: 600, historyRows: 3))
    }

    /// Unknown geometry is never pressure — the same first-layout-pass guard
    /// `fittedScale` has.
    func test_shouldYieldHistory_unlaidOutRoom_doesNotYield() {
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: 0, historyRows: 3))
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: -50, historyRows: 3))
    }

    // MARK: - yieldStep

    func test_yieldStep_everyPermittedRowIsDrawn_stepsByOne() {
        XCTAssertEqual(PresentationLayout.yieldStep(depth: 3, drawnRows: 3), 1)
        XCTAssertEqual(PresentationLayout.yieldStep(depth: 1, drawnRows: 1), 1)
    }

    /// The case a step of 1 would waste: the depth permits more rows than exist,
    /// so the first yields would drop rows that were never on screen and free no
    /// room at all.
    func test_yieldStep_depthExceedsDrawnRows_stepsPastThePhantomRows() {
        XCTAssertEqual(PresentationLayout.yieldStep(depth: 3, drawnRows: 1), 3)
        XCTAssertEqual(PresentationLayout.yieldStep(depth: 3, drawnRows: 2), 2)
    }

    func test_yieldStep_isNeverZeroOrNegative() {
        XCTAssertEqual(PresentationLayout.yieldStep(depth: 0, drawnRows: 3), 1)
        XCTAssertEqual(PresentationLayout.yieldStep(depth: 1, drawnRows: 9), 1)
    }

    /// The property the view depends on: one step always removes exactly one
    /// *drawn* row, whatever the depth and however few utterances exist.
    func test_yieldStep_alwaysShedsExactlyOneDrawnRow() {
        for utterances in 1...6 {
            var yielded = 0
            var depth = PresentationLayout.historyDepth(forScale: 1.0,
                                                        rowsYielded: yielded)
            var drawn = min(depth, utterances)
            while drawn > 0 {
                yielded += PresentationLayout.yieldStep(depth: depth,
                                                        drawnRows: drawn)
                depth = PresentationLayout.historyDepth(forScale: 1.0,
                                                        rowsYielded: yielded)
                let next = min(depth, utterances)
                XCTAssertEqual(next, drawn - 1, "utterances \(utterances)")
                drawn = next
            }
        }
    }

    /// The escalation as the view runs it: history is spent one drawn row at a
    /// time, and the fit is untouched for as long as a row remains.
    func test_escalation_spendsAllHistoryBeforeShrinkingLiveRow() {
        let room: CGFloat = 600
        let content: CGFloat = 700          // never fits, whatever we do
        let scale = 1.0
        let utterances = 5                  // more than any depth permits
        var yielded = 0
        var fit = 1.0

        for _ in 0..<10 {
            let depth = PresentationLayout.historyDepth(forScale: scale,
                                                        rowsYielded: yielded)
            let drawn = min(depth, utterances)
            if PresentationLayout.shouldYieldHistory(contentHeight: content,
                                                    room: room,
                                                    historyRows: drawn) {
                yielded += PresentationLayout.yieldStep(depth: depth,
                                                        drawnRows: drawn)
                XCTAssertEqual(fit, 1.0, accuracy: 1e-12,
                               "live row shrank while history still had rows")
            } else {
                fit = PresentationLayout.fittedScale(contentHeight: content,
                                                     room: room, current: fit)
            }
        }

        XCTAssertEqual(PresentationLayout.historyDepth(forScale: scale,
                                                       rowsYielded: yielded), 0)
        XCTAssertLessThan(fit, 1.0, "shrink never started")
    }

    // MARK: - fittedScale

    func test_fittedScale_contentFits_returnsCurrentUnchanged() {
        let result = PresentationLayout.fittedScale(contentHeight: 200,
                                                   room: 600, current: 1.4)
        XCTAssertEqual(result, 1.4, accuracy: 1e-12)
    }

    /// Exactly filling the room counts as fitting, not as overflow.
    func test_fittedScale_contentExactlyFillsRoom_returnsCurrent() {
        let result = PresentationLayout.fittedScale(contentHeight: 600,
                                                   room: 600, current: 1.0)
        XCTAssertEqual(result, 1.0, accuracy: 1e-12)
    }

    func test_fittedScale_overflow_takesExactlyOneStep() {
        let result = PresentationLayout.fittedScale(contentHeight: 900,
                                                   room: 600, current: 1.0)
        XCTAssertEqual(result, 1.0 - PresentationLayout.fitStep, accuracy: 1e-12)
    }

    /// The regression this guard exists for: a zero-height room on the first
    /// layout pass must not ratchet the text down, because nothing ever grows
    /// it back.
    func test_fittedScale_zeroRoom_returnsCurrentUnchanged() {
        let result = PresentationLayout.fittedScale(contentHeight: 900,
                                                   room: 0, current: 1.6)
        XCTAssertEqual(result, 1.6, accuracy: 1e-12)
    }

    func test_fittedScale_negativeRoom_returnsCurrentUnchanged() {
        let result = PresentationLayout.fittedScale(contentHeight: 900,
                                                   room: -50, current: 1.6)
        XCTAssertEqual(result, 1.6, accuracy: 1e-12)
    }

    func test_fittedScale_zeroContentWithZeroRoom_returnsCurrent() {
        let result = PresentationLayout.fittedScale(contentHeight: 0,
                                                   room: 0, current: 0.9)
        XCTAssertEqual(result, 0.9, accuracy: 1e-12)
    }

    func test_fittedScale_clampsToMinFit() {
        // 0.62 - 0.06 would be 0.56, below the legibility floor.
        let result = PresentationLayout.fittedScale(contentHeight: 5000,
                                                   room: 100, current: 0.62)
        XCTAssertEqual(result, PresentationLayout.minFit, accuracy: 1e-12)
    }

    func test_fittedScale_atMinFit_staysAtMinFit() {
        let result = PresentationLayout.fittedScale(
            contentHeight: 5000, room: 100,
            current: PresentationLayout.minFit)
        XCTAssertEqual(result, PresentationLayout.minFit, accuracy: 1e-12)
    }

    /// Repeated passes with content that never fits bottom out at minFit and
    /// stay there rather than marching negative.
    func test_fittedScale_repeatedOverflow_convergesToMinFit() {
        var scale = 1.6
        for _ in 0..<40 {
            scale = PresentationLayout.fittedScale(contentHeight: 5000,
                                                  room: 100, current: scale)
            XCTAssertGreaterThanOrEqual(scale, PresentationLayout.minFit)
        }
        XCTAssertEqual(scale, PresentationLayout.minFit, accuracy: 1e-12)
    }

    /// The real convergence case: height falls as the scale falls, so the loop
    /// should stop at the first scale that fits and then hold steady.
    func test_fittedScale_convergesToLargestFittingScale() {
        let room: CGFloat = 600
        // Height model: one measured pass per scale, proportional for the
        // purposes of the test (the real view re-measures reflowed text).
        func height(_ scale: Double) -> CGFloat { CGFloat(900.0 * scale) }

        var scale = 1.0
        var steps = 0
        while height(scale) > room, steps < 100 {
            scale = PresentationLayout.fittedScale(contentHeight: height(scale),
                                                   room: room, current: scale)
            steps += 1
        }
        XCTAssertLessThan(steps, 100, "did not converge")
        XCTAssertLessThanOrEqual(height(scale), room)
        // One step larger would have overflowed, i.e. it did not overshoot.
        XCTAssertGreaterThan(height(scale + PresentationLayout.fitStep), room)

        // Idempotent once it fits: further passes must not shrink further.
        let settled = scale
        for _ in 0..<5 {
            scale = PresentationLayout.fittedScale(contentHeight: height(scale),
                                                   room: room, current: scale)
        }
        XCTAssertEqual(scale, settled, accuracy: 1e-12)
    }

    /// Never grows the scale back up, even with acres of empty room.
    func test_fittedScale_neverGrows() {
        let result = PresentationLayout.fittedScale(contentHeight: 10,
                                                   room: 10_000, current: 0.8)
        XCTAssertEqual(result, 0.8, accuracy: 1e-12)
    }

    // MARK: - grownScale

    /// The regression this function exists for: a shrunken row in a window that
    /// has since grown must be able to come back up, or one long sentence in a
    /// small window leaves the projector permanently undersized.
    func test_grownScale_ampleRoom_takesExactlyOneStep() {
        let result = PresentationLayout.grownScale(contentHeight: 100,
                                                  room: 1_000, current: 0.7)
        XCTAssertEqual(result, 0.7 + PresentationLayout.fitStep, accuracy: 1e-12)
    }

    func test_grownScale_neverExceedsOne() {
        // 0.97 + 0.06 would be 1.03, past the user's own scale choice.
        let result = PresentationLayout.grownScale(contentHeight: 10,
                                                  room: 1_000, current: 0.97)
        XCTAssertEqual(result, 1.0, accuracy: 1e-12)
    }

    func test_grownScale_atFullSize_staysThere() {
        let result = PresentationLayout.grownScale(contentHeight: 10,
                                                  room: 1_000, current: 1.0)
        XCTAssertEqual(result, 1.0, accuracy: 1e-12)
    }

    /// Inside the hysteresis band — content already near the ceiling — growing
    /// would overflow on the next pass, so it does not grow.
    func test_grownScale_withinHysteresisBand_doesNotGrow() {
        let room: CGFloat = 1_000
        let justInside = CGFloat(PresentationLayout.growSlack) * room + 1
        let result = PresentationLayout.grownScale(contentHeight: justInside,
                                                  room: room, current: 0.8)
        XCTAssertEqual(result, 0.8, accuracy: 1e-12)
    }

    func test_grownScale_atSlackBoundary_doesNotGrow() {
        let room: CGFloat = 1_000
        let atBoundary = CGFloat(PresentationLayout.growSlack) * room
        let result = PresentationLayout.grownScale(contentHeight: atBoundary,
                                                  room: room, current: 0.8)
        XCTAssertEqual(result, 0.8, accuracy: 1e-12)
    }

    func test_grownScale_unlaidOutRoom_returnsCurrentUnchanged() {
        XCTAssertEqual(PresentationLayout.grownScale(contentHeight: 10, room: 0,
                                                     current: 0.7),
                       0.7, accuracy: 1e-12)
        XCTAssertEqual(PresentationLayout.grownScale(contentHeight: 10, room: -50,
                                                     current: 0.7),
                       0.7, accuracy: 1e-12)
    }

    /// Overflowing content is `fittedScale`'s business; growing must refuse it
    /// outright rather than relying on the caller to pick the right function.
    func test_grownScale_overflowingContent_doesNotGrow() {
        let result = PresentationLayout.grownScale(contentHeight: 1_200,
                                                  room: 600, current: 0.7)
        XCTAssertEqual(result, 0.7, accuracy: 1e-12)
    }

    /// The pair must settle, not trade steps forever. Height tracks scale, so a
    /// grow raises the measurement and a shrink lowers it — exactly the loop the
    /// slack band exists to break.
    func test_grownScale_andFittedScale_settleWithoutOscillating() {
        let room: CGFloat = 600
        func height(_ scale: Double) -> CGFloat { CGFloat(700.0 * scale) }

        var scale = PresentationLayout.minFit
        var seen: [Double] = []
        for _ in 0..<60 {
            let content = height(scale)
            scale = content > room
                ? PresentationLayout.fittedScale(contentHeight: content,
                                                 room: room, current: scale)
                : PresentationLayout.grownScale(contentHeight: content,
                                                room: room, current: scale)
            seen.append(scale)
        }

        // Settled: the last several passes agree.
        let settled = seen[seen.count - 1]
        for value in seen.suffix(5) {
            XCTAssertEqual(value, settled, accuracy: 1e-12, "kept moving")
        }
        // And it settled somewhere the content actually fits.
        XCTAssertLessThanOrEqual(height(settled), room)
    }

    // MARK: - historyOpacity

    func test_historyOpacity_emptyCount_doesNotCrash() {
        XCTAssertEqual(PresentationLayout.historyOpacity(index: 0, count: 0),
                       0.30, accuracy: 1e-12)
    }

    func test_historyOpacity_singleRow_isDimmest() {
        XCTAssertEqual(PresentationLayout.historyOpacity(index: 0, count: 1),
                       0.30, accuracy: 1e-12)
    }

    func test_historyOpacity_twoRows_spansFullRamp() {
        XCTAssertEqual(PresentationLayout.historyOpacity(index: 0, count: 2),
                       0.30, accuracy: 1e-12)
        XCTAssertEqual(PresentationLayout.historyOpacity(index: 1, count: 2),
                       0.58, accuracy: 1e-12)
    }

    func test_historyOpacity_threeRows_middleIsHalfway() {
        XCTAssertEqual(PresentationLayout.historyOpacity(index: 0, count: 3),
                       0.30, accuracy: 1e-12)
        XCTAssertEqual(PresentationLayout.historyOpacity(index: 1, count: 3),
                       0.44, accuracy: 1e-12)
        XCTAssertEqual(PresentationLayout.historyOpacity(index: 2, count: 3),
                       0.58, accuracy: 1e-12)
    }

    /// Newest history row is always brightest, and the ramp never reaches the
    /// live row's full opacity.
    func test_historyOpacity_increasesWithIndex_andStaysBelowLiveRow() {
        for count in 2...6 {
            var previous = -1.0
            for index in 0..<count {
                let opacity = PresentationLayout.historyOpacity(index: index,
                                                                count: count)
                XCTAssertGreaterThan(opacity, previous, "count \(count)")
                // Tolerance because the ramp arithmetic lands a hair above
                // 0.58 at the top (0.5800000000000001).
                XCTAssertGreaterThanOrEqual(opacity, 0.30 - 1e-9)
                XCTAssertLessThanOrEqual(opacity, 0.58 + 1e-9)
                previous = opacity
            }
            XCTAssertEqual(previous, 0.58, accuracy: 1e-12,
                           "newest row of \(count) should top the ramp")
        }
    }

    // MARK: - fontSize

    func test_fontSize_scalesFrom34Points() {
        XCTAssertEqual(PresentationLayout.fontSize(scale: 1.0), 34)
        XCTAssertEqual(PresentationLayout.fontSize(scale: 1.5), 51)
        XCTAssertEqual(PresentationLayout.fontSize(scale: 2.0), 68)
    }

    func test_fontSize_roundsToWholePoints() {
        XCTAssertEqual(PresentationLayout.fontSize(scale: 0.6), 20)   // 20.4
        XCTAssertEqual(PresentationLayout.fontSize(scale: 1.06), 36)  // 36.04
        XCTAssertEqual(PresentationLayout.fontSize(scale: 1.2), 41)   // 40.8
        XCTAssertEqual(PresentationLayout.fontSize(scale: 2.2), 75)   // 74.8
        XCTAssertEqual(PresentationLayout.fontSize(scale: 3.2), 109)  // 108.8
    }

    /// Exact halves round away from zero, matching `Double.rounded()`.
    func test_fontSize_roundsHalvesUp() {
        XCTAssertEqual(PresentationLayout.fontSize(scale: 1.25), 43)  // 42.5
        XCTAssertEqual(PresentationLayout.fontSize(scale: 0.75), 26)  // 25.5
    }

    func test_fontSize_neverShrinksWithScale() {
        var previous = PresentationLayout.fontSize(scale: 0.6)
        var scale = 0.6
        while scale <= 3.2 {
            let size = PresentationLayout.fontSize(scale: scale)
            XCTAssertGreaterThanOrEqual(size, previous, "scale \(scale)")
            previous = size
            scale += 0.12
        }
    }
}
