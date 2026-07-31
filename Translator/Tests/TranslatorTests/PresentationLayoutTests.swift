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

    // MARK: - Room

    /// The distinction the type exists for: no measurement yet is not the same
    /// state as no room left, and it must not be mistaken for it.
    func test_room_unmeasuredIsNotExhausted() {
        XCTAssertNil(PresentationLayout.Room.unmeasured.measuredHeight)
        XCTAssertFalse(PresentationLayout.Room.unmeasured.isExhausted)
    }

    func test_room_measuredNonPositiveIsExhausted() {
        XCTAssertTrue(PresentationLayout.Room.measured(0).isExhausted)
        XCTAssertTrue(PresentationLayout.Room.measured(-120).isExhausted)
        XCTAssertFalse(PresentationLayout.Room.measured(1).isExhausted)
        XCTAssertEqual(PresentationLayout.Room.measured(-120).measuredHeight, -120)
    }

    /// They must not compare equal either, or the view's `onChange` would sleep
    /// through the transition from "not laid out" to "no room left".
    func test_room_unmeasuredDiffersFromAMeasuredZero() {
        XCTAssertNotEqual(PresentationLayout.Room.unmeasured,
                          PresentationLayout.Room.measured(0))
    }

    // MARK: - shouldYieldHistory

    func test_shouldYieldHistory_overflowWithHistoryDrawn_yields() {
        XCTAssertTrue(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: .measured(600), historyRows: 3))
    }

    /// The invariant this rule exists for: the live row shrinks only once there
    /// is no drawn history left to take room from, so it can never be set
    /// smaller than the settled lines above it.
    func test_shouldYieldHistory_noHistoryDrawn_shrinksInstead() {
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: .measured(600), historyRows: 0))
    }

    func test_shouldYieldHistory_contentFits_doesNotYield() {
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 600, room: .measured(600), historyRows: 3))
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 100, room: .measured(600), historyRows: 3))
    }

    /// Unknown geometry is never pressure — the same first-layout-pass guard
    /// `fittedScale` has.
    func test_shouldYieldHistory_unmeasuredRoom_doesNotYield() {
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: .unmeasured, historyRows: 3))
    }

    /// **The defect the `Room` type exists for.** History has consumed the whole
    /// feed, so the live row's room genuinely computes to zero or less. That is
    /// maximum pressure, and `.measured(0)` is the exact input the clamped
    /// version produced and then misread as "not laid out yet": nothing
    /// overflowed, this was never consulted, history never yielded, and the live
    /// row stayed clipped with no escape.
    func test_shouldYieldHistory_exhaustedRoom_yieldsImmediately() {
        XCTAssertTrue(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: .measured(0), historyRows: 3))
        XCTAssertTrue(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: .measured(-120), historyRows: 1))
    }

    /// And it yields on the room alone: a row handed no height cannot report an
    /// overflow, so waiting for one is precisely how the escalation deadlocked.
    func test_shouldYieldHistory_exhaustedRoomBeforeTheLiveRowIsMeasured_yields() {
        XCTAssertTrue(PresentationLayout.shouldYieldHistory(
            contentHeight: 0, room: .measured(-40), historyRows: 2))
    }

    /// Exhausted or not, a row that is not on screen frees nothing: with no
    /// drawn history the shrink path is the only one left.
    func test_shouldYieldHistory_exhaustedRoomWithNoHistoryDrawn_doesNotYield() {
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: .measured(0), historyRows: 0))
        XCTAssertFalse(PresentationLayout.shouldYieldHistory(
            contentHeight: 700, room: .measured(-40), historyRows: 0))
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
                                                    room: .measured(room),
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

    /// The escape the clamped room denied, run end to end: history is tall enough
    /// that the live row's room is *negative*, so the escalation has to start
    /// from a non-positive measurement — and it has to stop as soon as one row's
    /// worth of height has been freed, without ever shrinking the live text,
    /// because history still had rows to give.
    func test_escalation_exhaustedRoom_yieldsHistoryUntilTheLiveRowFits() {
        let feed: CGFloat = 400             // room the whole feed lives in
        let historyRowHeight: CGFloat = 140 // one settled row at this scale
        let liveHeight: CGFloat = 110
        let scale = 1.0
        let utterances = 3
        var yielded = 0
        var fit = 1.0

        func room(rows: Int) -> PresentationLayout.Room {
            .measured(feed - historyRowHeight * CGFloat(rows))
        }
        func drawn() -> Int {
            min(PresentationLayout.historyDepth(forScale: scale, rowsYielded: yielded),
                utterances)
        }

        XCTAssertEqual(drawn(), 3)
        XCTAssertTrue(room(rows: drawn()).isExhausted,
                      "setup: the live row should start with no room at all")

        for _ in 0..<10 {
            let current = room(rows: drawn())
            if PresentationLayout.shouldYieldHistory(contentHeight: liveHeight,
                                                    room: current,
                                                    historyRows: drawn()) {
                let depth = PresentationLayout.historyDepth(forScale: scale,
                                                            rowsYielded: yielded)
                yielded += PresentationLayout.yieldStep(depth: depth,
                                                        drawnRows: drawn())
            } else {
                fit = PresentationLayout.fittedScale(contentHeight: liveHeight,
                                                     in: current, current: fit)
            }
        }

        // Exactly one row bought enough room, so exactly one row went.
        XCTAssertEqual(drawn(), 2)
        let settled = room(rows: drawn())
        XCTAssertFalse(settled.isExhausted, "still clipped: \(settled)")
        XCTAssertGreaterThanOrEqual(settled.measuredHeight ?? 0, liveHeight)
        XCTAssertEqual(fit, 1.0, accuracy: 1e-12,
                       "live text shrank while history still had rows to give")
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

    // MARK: - fittedScale(in:)

    func test_fittedScaleInRoom_unmeasured_returnsCurrentUnchanged() {
        XCTAssertEqual(PresentationLayout.fittedScale(contentHeight: 900,
                                                     in: .unmeasured,
                                                     current: 1.6),
                       1.6, accuracy: 1e-12)
    }

    func test_fittedScaleInRoom_measured_matchesTheHeightRule() {
        XCTAssertEqual(PresentationLayout.fittedScale(contentHeight: 900,
                                                     in: .measured(600),
                                                     current: 1.0),
                       1.0 - PresentationLayout.fitStep, accuracy: 1e-12)
        XCTAssertEqual(PresentationLayout.fittedScale(contentHeight: 200,
                                                     in: .measured(600),
                                                     current: 1.0),
                       1.0, accuracy: 1e-12)
    }

    /// Maximum pressure. By the time the view asks this, history has already
    /// given up every row it had, so the live text is the only lever left — and
    /// it must move without waiting for an overflow that a zero-height row can
    /// never report.
    func test_fittedScaleInRoom_exhausted_shrinksOneStep() {
        XCTAssertEqual(PresentationLayout.fittedScale(contentHeight: 0,
                                                     in: .measured(0),
                                                     current: 1.0),
                       1.0 - PresentationLayout.fitStep, accuracy: 1e-12)
        XCTAssertEqual(PresentationLayout.fittedScale(contentHeight: 10,
                                                     in: .measured(-80),
                                                     current: 0.9),
                       0.9 - PresentationLayout.fitStep, accuracy: 1e-12)
    }

    func test_fittedScaleInRoom_exhausted_stillStopsAtMinFit() {
        var scale = 1.0
        for _ in 0..<40 {
            scale = PresentationLayout.fittedScale(contentHeight: 500,
                                                  in: .measured(-500),
                                                  current: scale)
            XCTAssertGreaterThanOrEqual(scale, PresentationLayout.minFit)
        }
        XCTAssertEqual(scale, PresentationLayout.minFit, accuracy: 1e-12)
    }

    // MARK: - Fit termination (the oscillation defect)

    /// Room for the step-function model below, chosen so the line-count drop
    /// straddles exactly one `fitStep`.
    private static let steppedRoom: CGFloat = 80

    /// Height as a **step function** of scale, which is the shape the real view
    /// has: shrinking the type does not shrink the row smoothly, it eventually
    /// re-wraps the sentence onto one fewer line and the height falls by a whole
    /// line box at once.
    ///
    /// With 30 units of text, 12 units to a line and a 40pt line box, the row
    /// needs 3 lines (98.4pt) at scale 0.82 and only 2 (60.8pt) one step down —
    /// against 80pt of room, the exact trap the old shrink/grow pair fell into:
    /// 98.4 > 80 so it shrank, then 60.8 < 0.88 × 80 = 70.4 so it grew straight
    /// back, forever, re-rendering the caption on every pass. **A linear height
    /// model cannot reproduce that**, which is the whole reason this one is a step
    /// function.
    private static func steppedHeight(atScale scale: Double) -> CGFloat {
        let textUnits = 30.0
        let lineCapacity = 12.0
        let lineHeight = 40.0
        let lines = (textUnits * scale / lineCapacity).rounded(.up)
        return CGFloat(lines * lineHeight * scale)
    }

    /// Guards the model itself: if it ever stops stepping, the test below stops
    /// testing anything.
    func test_steppedHeightModel_dropsAWholeLineAcrossOneStep() {
        let high = Self.steppedHeight(atScale: 0.82)
        let low = Self.steppedHeight(atScale: 0.82 - PresentationLayout.fitStep)
        XCTAssertGreaterThan(high, Self.steppedRoom, "must overflow at 0.82")
        XCTAssertLessThan(low, Self.steppedRoom, "must fit one step down")
        // The drop is a whole line — far more than any percentage-of-height
        // hysteresis band could bridge, which is why widening the old 12% band
        // was never an option: at 0.88 × room the lower height is still well
        // inside the band, so the old rule grew straight back up.
        XCTAssertLessThan(Double(low), 0.88 * Double(Self.steppedRoom))
        XCTAssertGreaterThan(Double(high - low), 0.12 * Double(Self.steppedRoom))
    }

    /// **The regression test for the oscillation.** Driven against the step
    /// function above, the fit must reach a fixed point within the bound the
    /// rules advertise and must never revisit a scale it has left.
    ///
    /// The loop mirrors `PresentationView.applyFit`'s fit branch exactly: one
    /// call per pass and nothing that can raise the fit. Reintroducing a grow
    /// step there means mirroring it here, and this test then fails — under the
    /// old pair the trace was `1.0 0.94 0.88 0.82 0.76 0.82 0.76 …` forever.
    func test_fit_stepFunctionHeight_reachesAFixedPointAndNeverCycles() {
        var fit = 1.0
        var trace: [Double] = [fit]

        for _ in 0...(PresentationLayout.maxFitSteps + 5) {
            let content = Self.steppedHeight(atScale: fit)
            let next = PresentationLayout.fittedScale(
                contentHeight: content, in: .measured(Self.steppedRoom), current: fit)
            XCTAssertLessThanOrEqual(next, fit,
                                     "the fit grew, which is how it used to cycle")
            if fit - next > 0.005 { fit = next }
            trace.append(fit)
        }

        // Reached a fixed point: the last several passes all agree.
        XCTAssertEqual(Set(trace.suffix(6)).count, 1, "still moving: \(trace)")

        // Within the advertised bound.
        let changes = zip(trace, trace.dropFirst()).filter { $0 != $1 }.count
        XCTAssertLessThanOrEqual(changes, PresentationLayout.maxFitSteps,
                                 "took more steps than maxFitSteps: \(trace)")

        // And no scale is ever returned to once left — no cycle of any length.
        var visited: [Double] = []
        for value in trace where visited.last != value { visited.append(value) }
        XCTAssertEqual(visited.count, Set(visited).count,
                       "revisited a scale: \(trace)")

        // It settled somewhere the content genuinely fits.
        let settled = fit
        XCTAssertLessThanOrEqual(Self.steppedHeight(atScale: settled),
                                 Self.steppedRoom)
    }

    /// The structural property the termination argument rests on, checked over a
    /// grid rather than argued: *no* input makes the fit larger. A rule that both
    /// shrank and grew is exactly what oscillated, so this is the invariant that
    /// must not be reintroduced.
    func test_fittedScale_neverReturnsMoreThanCurrent() {
        let rooms: [PresentationLayout.Room] = [
            .unmeasured, .measured(-100), .measured(0), .measured(1),
            .measured(120), .measured(5_000),
        ]
        let heights: [CGFloat] = [0, 1, 60, 119, 120, 121, 4_000]
        let scales = [PresentationLayout.minFit, 0.62, 0.7, 0.88, 1.0]
        for room in rooms {
            for content in heights {
                for current in scales {
                    let next = PresentationLayout.fittedScale(contentHeight: content,
                                                             in: room,
                                                             current: current)
                    XCTAssertLessThanOrEqual(next, current,
                                             "\(room) \(content) \(current)")
                    XCTAssertGreaterThanOrEqual(next, PresentationLayout.minFit)
                }
            }
        }
    }

    /// `maxFitSteps` must be the real distance from full size to the floor — the
    /// view quotes it as its termination bound.
    func test_maxFitSteps_isTheDistanceFromFullSizeToMinFit() {
        XCTAssertEqual(PresentationLayout.maxFitSteps, 7)

        var scale = 1.0
        var steps = 0
        for _ in 0..<100 where scale > PresentationLayout.minFit {
            scale = PresentationLayout.fittedScale(contentHeight: 5_000, room: 10,
                                                   current: scale)
            steps += 1
        }
        XCTAssertEqual(scale, PresentationLayout.minFit, accuracy: 1e-12)
        XCTAssertEqual(steps, PresentationLayout.maxFitSteps)
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

    // MARK: - letterCount

    func test_letterCount_emptyAndUnletteredText_isZero() {
        XCTAssertEqual(PresentationLayout.letterCount("", cappedAt: 8), 0)
        XCTAssertEqual(PresentationLayout.letterCount("12:30", cappedAt: 8), 0)
        XCTAssertEqual(PresentationLayout.letterCount("1,500 …?!", cappedAt: 8), 0)
        XCTAssertEqual(PresentationLayout.letterCount("   ", cappedAt: 8), 0)
    }

    /// Counts exactly what `ScriptDetector` judges on — Hangul (including bare
    /// jamo) and Latin (including accented forms), and nothing else. Digits are
    /// what make a short opening undecidable, so they must not count as evidence.
    func test_letterCount_countsTheSameScalarsScriptDetectorJudges() {
        XCTAssertEqual(PresentationLayout.letterCount("KTX", cappedAt: 8), 3)
        XCTAssertEqual(PresentationLayout.letterCount("안녕", cappedAt: 8), 2)
        XCTAssertEqual(PresentationLayout.letterCount("café", cappedAt: 8), 4)
        XCTAssertEqual(PresentationLayout.letterCount("\u{3131}\u{1100}", cappedAt: 8), 2)
        XCTAssertEqual(PresentationLayout.letterCount("2024년부터 3%", cappedAt: 8), 3)
    }

    /// The cap is what keeps the view's `onChange` asleep once the threshold has
    /// been reached: past it, more text cannot change the answer.
    func test_letterCount_stopsAtTheCap() {
        XCTAssertEqual(PresentationLayout.letterCount("안녕하세요 반갑습니다",
                                                     cappedAt: 3), 3)
        XCTAssertEqual(PresentationLayout.letterCount("안녕하세요 반갑", cappedAt: 7), 7)
        XCTAssertEqual(PresentationLayout.letterCount("안녕하세요 반갑습니다 또 만나요",
                                                     cappedAt: 7), 7)
    }

    func test_letterCount_nonPositiveCap_countsNothing() {
        XCTAssertEqual(PresentationLayout.letterCount("안녕하세요", cappedAt: 0), 0)
        XCTAssertEqual(PresentationLayout.letterCount("안녕하세요", cappedAt: -1), 0)
    }

    // MARK: - canLatchLanguage

    /// **The defect this rule exists for.** The first delta is the shortest and
    /// least reliable text there will ever be, so two or three characters must
    /// not decide which column each text goes in for the whole utterance.
    func test_canLatchLanguage_thinEvidence_keepsTracking() {
        for letters in 0..<PresentationLayout.languageLatchLetters {
            XCTAssertFalse(PresentationLayout.canLatchLanguage(letterCount: letters,
                                                              isHypothesis: true),
                           "\(letters) letters")
        }
    }

    func test_canLatchLanguage_enoughEvidence_latches() {
        XCTAssertTrue(PresentationLayout.canLatchLanguage(
            letterCount: PresentationLayout.languageLatchLetters,
            isHypothesis: true))
        XCTAssertTrue(PresentationLayout.canLatchLanguage(
            letterCount: PresentationLayout.languageLatchLetters + 40,
            isHypothesis: true))
    }

    /// Past `.hypothesis` the language is arbitrated (or pinned) and
    /// authoritative, so it is adopted whatever the text length — including an
    /// utterance carrying no letters at all.
    func test_canLatchLanguage_nonHypothesis_latchesRegardlessOfEvidence() {
        XCTAssertTrue(PresentationLayout.canLatchLanguage(letterCount: 0,
                                                          isHypothesis: false))
        XCTAssertTrue(PresentationLayout.canLatchLanguage(letterCount: 1,
                                                          isHypothesis: false))
    }

    /// A hypothesis that never gathers enough letters never latches, which is the
    /// right answer rather than a gap: it keeps self-correcting.
    func test_canLatchLanguage_unletteredHypothesis_neverLatches() {
        let letters = PresentationLayout.letterCount(
            "12:30 — 100%", cappedAt: PresentationLayout.languageLatchLetters)
        XCTAssertEqual(letters, 0)
        XCTAssertFalse(PresentationLayout.canLatchLanguage(letterCount: letters,
                                                          isHypothesis: true))
    }

    /// The argument for the threshold's *value*, as a test. At three letters a
    /// Korean sentence that opens with an acronym reads as English — the answer
    /// the old latch froze for the whole utterance — and by
    /// `languageLatchLetters` the Hangul that followed has outvoted it.
    func test_languageLatchLetters_outvotesAThreeLetterRomanizedOpening() {
        let opening = "KTX"
        XCTAssertEqual(PresentationLayout.letterCount(opening, cappedAt: 8), 3)
        XCTAssertEqual(ScriptDetector.language(of: opening), .en)

        let atThreshold = opening + String(
            repeating: "가",
            count: PresentationLayout.languageLatchLetters - opening.count)
        XCTAssertEqual(PresentationLayout.letterCount(
            atThreshold, cappedAt: PresentationLayout.languageLatchLetters),
                       PresentationLayout.languageLatchLetters)
        XCTAssertEqual(ScriptDetector.language(of: atThreshold), .ko)
    }

    /// Bounds on the threshold itself: high enough that a three-letter opening
    /// cannot carry the vote, low enough that a normal sentence latches within
    /// its first two or three words instead of flickering throughout.
    func test_languageLatchLetters_staysInTheJustifiedRange() {
        XCTAssertGreaterThanOrEqual(PresentationLayout.languageLatchLetters, 6)
        XCTAssertLessThanOrEqual(PresentationLayout.languageLatchLetters, 8)
    }
}
