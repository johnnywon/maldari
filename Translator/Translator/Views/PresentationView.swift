import SwiftUI

/// Guest-facing Presentation Mode: one bilingual feed — Korean left, English
/// right, always in that order regardless of who spoke — sized to be read from
/// across a meeting room.
///
/// The visual language is a faithful port of an approved design, so the numbers
/// (68pt header, 28pt header gutters, 56pt feed gutters, 64pt column gap, 30pt
/// row gap) are decisions, not defaults. Change them in the design first.
///
/// **Typography.** The source design specified IBM Plex Sans / Plex Sans KR,
/// which macOS does not ship. Rather than bundle a font we render in SF Pro via
/// `Theme.sans` — the face the rest of the app already uses — and let Hangul
/// fall through to the system Korean face. Only the clock is monospaced.
///
/// **`@MainActor` on a View** is unusual for this file's neighbours and it is
/// load-bearing: the chrome auto-hide spawns a `Task` that mutates view state,
/// and Swift 6 only permits that closure to capture the view when both the
/// enclosing context and the task are known to be main-actor isolated.
@MainActor
struct PresentationView: View {
    @Bindable var pipeline: PipelineController
    @Bindable var settings: AppSettings

    // MARK: - Layout constants (from the design; see the type doc)

    private static let headerHeight: CGFloat = 68
    private static let headerGutter: CGFloat = 28
    private static let headerItemGap: CGFloat = 18
    private static let feedGutter: CGFloat = 56
    private static let feedTopPadding: CGFloat = 40
    private static let feedBottomPadding: CGFloat = 48
    private static let columnGap: CGFloat = 64
    private static let rowGap: CGFloat = 30
    private static let dividerHeight: CGFloat = 1

    // MARK: - View state

    /// Auto-fit multiplier applied on top of the user's font scale so a long
    /// sentence shrinks instead of clipping. Reset to 1 on every new utterance,
    /// on every manual scale change and on every window resize — otherwise one
    /// long sentence would hold the whole meeting at a smaller size.
    ///
    /// Between two of those resets it only ever *falls* (see `applyFit`), which
    /// is what stops the fit from oscillating: the resets are the only way back
    /// up.
    @State private var fit: Double = 1.0

    /// The three measurements the auto-fit is a function of.
    ///
    /// All three are state, and the fit re-runs when *any* of them moves,
    /// because the fit used to be driven from the live row's height measurement
    /// alone: a change in the available *room* — a window resize, a history row
    /// appearing or disappearing — never re-evaluated it, so the feed quietly
    /// outgrew its container and painted over the header.
    @State private var historyHeight: CGFloat = 0
    @State private var liveContentHeight: CGFloat = 0
    @State private var feedHeight: CGFloat = 0

    /// History rows surrendered so the live row can keep its size. Raised by one
    /// *drawn* row per measurement while the live row overflows (see
    /// `PresentationLayout.yieldStep`) and reset whenever the fit resets, so
    /// pressure never outlives the sentence that caused it.
    @State private var historyYield: Int = 0

    /// The language the live row is *drawn* with: which column each text goes
    /// in and which accent it wears, held steady for one hypothesis.
    ///
    /// Held rather than read live, because `Utterance.sourceLanguage` for a
    /// hypothesis is `ScriptDetector`'s answer over however much text has
    /// arrived so far, and that answer genuinely flips as the sentence grows —
    /// a Korean sentence opening with a number or a romanized product name
    /// reads as English for its first few deltas. Recomputing it every render
    /// made the two columns trade places and the accent change colour
    /// mid-sentence, in front of the room.
    ///
    /// **`latched` is why this is not simply the first answer.** Adopting the
    /// first detection and holding it froze the *least* reliable reading there
    /// will ever be — two or three characters — for the whole utterance, so a
    /// sentence opening with an acronym spent its entire life in the wrong
    /// columns. Before the latch existed at least the row self-corrected. So the
    /// value is re-adopted on every change while the evidence is thin and only
    /// frozen once there is enough of it (`PresentationLayout.canLatchLanguage`).
    @State private var liveLanguageLatch: LiveLanguage?

    /// A language decision for the live row: which language, for which
    /// utterance, and whether it is final.
    private struct LiveLanguage: Equatable {
        let id: Int
        let language: Language
        /// True once the answer came from enough text — or from a source state
        /// past `.hypothesis`, which is authoritative — to be worth freezing.
        /// While false the view keeps re-adopting the current detection.
        let latched: Bool
    }

    /// Chrome (the header) fades after 3s of mouse stillness. Its 68pt of space
    /// stays reserved while hidden: text jumping mid-meeting is far worse than
    /// a visible header.
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var lastChromeBump: Date = .distantPast

    /// Drives the 240ms opacity settle on corrected words. `settleKey` changes
    /// once per revision that carries corrections, so the animation fires on
    /// the rewrite and not on every redraw.
    ///
    /// A `OneShot` and not a bare `Double`: the obvious spelling of a one-shot
    /// (`progress = 0` then `withAnimation { progress = 1 }`) is a guaranteed
    /// no-op here. See `OneShot`.
    @State private var settleShot = OneShot()

    /// The newest settle already played for each of the last few utterances,
    /// oldest first.
    ///
    /// A change in `settleKey` is not by itself a revision: when a hypothesis is
    /// aborted, `live` falls back to `newestFinalized`, so the key changes *back*
    /// to a sentence that settled minutes ago and the fade replayed on text
    /// nobody had touched. Remembering what has played makes the settle fire once
    /// per revision instead of once per key change.
    ///
    /// One slot per utterance rather than one per revision, which is what makes
    /// the bound safe: a single long hypothesis can carry dozens of corrected
    /// revisions, and a queue of revisions would evict the very finalized
    /// sentence the fallback is about to land on.
    @State private var playedSettles: [SettleKey] = []
    private static let settleMemory = 8

    /// One-shot "translation is final" rule beneath the English column.
    /// `ruleUtteranceID` records which utterance has already had its rule, so a
    /// redelivered id cannot replay it.
    @State private var ruleShot = OneShot()
    @State private var ruleUtteranceID: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
                .opacity(chromeVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: chromeVisible)
            feed
        }
        .background(Palette.background)
        .onContinuousHover { phase in
            if case .active = phase { bumpChrome() }
        }
        // Bring the chrome back the moment a session ends, without waiting for the
        // operator to find the window with the mouse. Stopping is exactly when they
        // need the controls again, and the hide timer would otherwise leave the
        // window blank until it was hovered.
        .onChange(of: pipeline.isListening) { _, listening in
            if !listening {
                hideTask?.cancel()
                chromeVisible = true
            } else {
                bumpChrome()
            }
        }
        .onDisappear { hideTask?.cancel() }
        // Keyed on the id of the utterance the live row actually *renders*.
        // Keying it on `utterances.last` meant a final inserted mid-array (finals
        // are backdated by their duration, so they often are) never reset the
        // auto-fit, and a new sentence inherited the previous one's shrink.
        .onChange(of: live?.id) { _, _ in resetFit() }
        .onChange(of: settings.presentationFontScale) { _, _ in resetFit() }
        // A change in the *feed's own* height is a window resize, and it is the
        // only room change allowed to reset the fit. Resetting on `liveRoom`
        // would loop forever instead: yielding a history row shrinks history,
        // which changes the room, which would restore the row, which overflows
        // again. The feed's height is safe to key on because the header's 68pt
        // stays reserved while hidden, so chrome auto-hide never moves it.
        .onChange(of: feedHeight) { _, _ in resetFit() }
        // One evaluation per change in *any* fit input — content height, room,
        // or the pressure already applied. `initial` so a window that opens with
        // an overlong sentence already in the feed is fitted on its first pass.
        .onChange(of: fitInput, initial: true) { _, input in applyFit(input) }
        // Latch the live row's language per hypothesis rather than per render.
        // See `liveLanguageLatch`.
        .onChange(of: liveLanguageSample, initial: true) { _, sample in
            adoptLiveLanguage(sample)
        }
        // Driven by a *change* in `settleKey` and never by the mere presence of
        // corrected indices: nobody ever clears `SpeculativeText.correctedIndices`
        // (its doc comment claims this view does — that claim is false), so a
        // presence test would replay the settle on every unrelated redraw.
        .onChange(of: settleKey) { _, key in fireSettle(for: key) }
        .onChange(of: finalRuleID) { _, id in
            guard let id else { return }
            fireFinalRule(for: id)
        }
        // Every one-shot memory here is keyed by utterance id, and ids restart
        // with the session: without this, the first utterances of a restarted
        // session inherit the previous session's verdicts — an id that already
        // had its rule silently loses it, and a latched language from a sentence
        // nobody in the room ever heard decides the new one's columns.
        .onChange(of: pipeline.store.sessionStart) { _, _ in resetSessionMemory() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: Self.headerItemGap) {
                brand
                Rectangle()
                    .fill(Palette.rule)
                    .frame(width: 1, height: 20)
                LevelMeter(pipeline: pipeline, accent: liveAccent)
                clock
            }
            Spacer(minLength: Self.headerItemGap)
            HStack(spacing: 10) {
                fontGroup
                transportButton
            }
        }
        .padding(.horizontal, Self.headerGutter)
        .frame(height: Self.headerHeight)
        .background(Palette.headerBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.headerHairline).frame(height: 1)
        }
    }

    /// Dot · 말 · MALDARI. The design gives 18pt between header *items*; the
    /// three pieces of the wordmark are one item, tightened to 8pt so the dot
    /// reads as part of the logo rather than as a separate status light.
    private var brand: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.accentKO)
                .frame(width: 8, height: 8)
            Text(verbatim: "말")
                .font(Theme.sans(size: 15, weight: .medium))
                .foregroundColor(Palette.accentKO)
            Text(verbatim: "MALDARI")
                .font(Theme.sans(size: 13, weight: .semibold))
                .tracking(13 * 0.16)
                .foregroundColor(Palette.brand)
        }
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(elapsed)
                .font(Theme.mono(size: 12))
                .monospacedDigit()
                .foregroundColor(Palette.meta)
        }
    }

    private var elapsed: String {
        guard let start = pipeline.store.sessionStart else { return "0:00" }
        let total = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var fontGroup: some View {
        HStack(spacing: 0) {
            StepButton(glyph: "\u{2212}") { stepScale(-1) }   // real minus sign
            StepButton(glyph: "+") { stepScale(+1) }
        }
        .padding(4)
        .background(controlBackground(cornerRadius: 8))
    }

    private var transportButton: some View {
        Button {
            pipeline.toggleListening()
        } label: {
            ZStack {
                if pipeline.isListening {
                    HStack(spacing: 4) {
                        pauseBar
                        pauseBar
                    }
                } else {
                    PlayTriangle()
                        .fill(Palette.icon)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 40, height: 40)
            .background(controlBackground(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pipeline.isListening ? "Pause listening" : "Resume listening")
    }

    private var pauseBar: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Palette.icon)
            .frame(width: 3, height: 14)
    }

    private func controlBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Palette.controlFill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Palette.controlBorder, lineWidth: 1)
            )
    }

    /// `AppSettings.presentationFontScale` clamps itself in `didSet`, but the
    /// clamp is repeated here so a click at the limit is a no-op instead of a
    /// write that bounces back through UserDefaults.
    private func stepScale(_ direction: Int) {
        let next = settings.presentationFontScale
            + Double(direction) * AppSettings.presentationScaleStep
        let clamped = min(max(next, AppSettings.minPresentationScale),
                          AppSettings.maxPresentationScale)
        if clamped != settings.presentationFontScale {
            settings.presentationFontScale = clamped
        }
    }

    // MARK: - Chrome auto-hide

    /// Restart the 3s hide countdown. `onContinuousHover` fires on every mouse
    /// move, so the reschedule is throttled to ~2.5/s while the header is
    /// already visible — the timer only needs to be accurate to a fraction of
    /// a second against a 3s deadline.
    ///
    /// **Only hides while a session is running.** The countdown used to start
    /// unconditionally, including at launch before the operator had touched the
    /// window at all: three seconds after Presentation Mode opened, the header
    /// faded and the window became a plain dark rectangle with no wordmark, no
    /// clock, no font controls and no Start button — and nothing on screen hinting
    /// that moving the mouse would bring them back. Verified by screenshotting a
    /// freshly-launched window.
    ///
    /// Hiding chrome exists to keep a *guest-facing* screen clean while captions
    /// flow. Idle, the feed is empty, so hiding the header declutters nothing and
    /// costs the operator every control. It also can't strand them any more: the
    /// only way into a session is the Start button in that header.
    private func bumpChrome() {
        let now = Date()
        if chromeVisible, now.timeIntervalSince(lastChromeBump) < 0.4 { return }
        lastChromeBump = now
        chromeVisible = true
        hideTask?.cancel()
        guard pipeline.isListening else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, pipeline.isListening else { return }
            chromeVisible = false
        }
    }

    // MARK: - Feed

    /// History flattened to exactly what a row draws, oldest first. Built here
    /// rather than in the row so the opacity ramp sees the final count — the
    /// depth shrinks as the font grows, and `historyOpacity` needs both.
    ///
    /// History is every utterance the live row is not currently drawing, so the
    /// two stay disjoint and no sentence appears twice.
    ///
    /// The boundary is the live row's **id**, excluded by id rather than by
    /// `dropLast()`: `TranscriptStore.apply` backdates a final by its reported
    /// duration and inserts by timestamp, and only the Korean engine reports a
    /// duration — so a long Korean sentence can land at index 0 while a later,
    /// shorter English "okay" sits at `last`. `dropLast()` therefore dropped the
    /// wrong row: the sentence the room had just heard was demoted to history
    /// *and* duplicated by the live row, and at a shallow `historyDepth` the
    /// newest utterance could fall off the end and be drawn nowhere at all.
    ///
    /// Keying on `live?.id` rather than on `newestFinalized?.id` matters while a
    /// hypothesis is in flight: the hypothesis is not in `utterances` at all, so
    /// nothing is excluded and the last completed sentence stays visible in
    /// history for the whole of the next one. Excluding `newestFinalized`
    /// unconditionally would instead punch a hole in the feed — that sentence
    /// would be in neither the live row nor history until the *next* final
    /// landed, then pop into existence.
    ///
    /// `rowsYielded` is what makes the depth respond to pressure and not to the
    /// font scale alone: when the live row will not fit, the room comes out of
    /// history before it comes out of the live text. See `applyFit`.
    private var historyEntries: [HistoryEntry] {
        let liveID = live?.id
        let past = pipeline.store.utterances.filter { $0.id != liveID }
        guard !past.isEmpty else { return [] }
        let depth = PresentationLayout.historyDepth(
            forScale: settings.presentationFontScale,
            rowsYielded: historyYield)
        let rows = Array(past.suffix(max(0, depth)))
        return rows.enumerated().map { index, utterance in
            HistoryEntry(
                id: utterance.id,
                korean: utterance.korean,
                english: utterance.english,
                accent: Self.accent(for: utterance.sourceLanguage),
                opacity: PresentationLayout.historyOpacity(
                    index: index, count: rows.count))
        }
    }

    /// Every measurement is *reported into state* here and nothing is decided
    /// here. The fit used to be computed inside the live row's own height
    /// reader, which is why it only ever reacted to the live row growing; the
    /// decision now lives in one `onChange` that sees all of its inputs.
    private var feed: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: Self.rowGap) {
                historyStack
                    .background { heightReader { historyHeight = $0 } }
                fadingDivider
                liveRow
                    .background { heightReader { liveContentHeight = $0 } }
            }
            .padding(.top, Self.feedTopPadding)
            .padding(.horizontal, Self.feedGutter)
            .padding(.bottom, Self.feedBottomPadding)
            // Bottom-anchored: the live row sits at a fixed height off the
            // floor and history grows upward, so the audience's eyes never
            // have to track a moving line.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // The container's height, not the content's: this is the room the
            // feed has to live within, and a change in it is a resize.
            .onChange(of: geo.size.height, initial: true) { _, height in
                feedHeight = height
            }
        }
    }

    /// History uses the raw font scale, never the live row's auto-fit
    /// multiplier: settled lines must not resize because the *current* sentence
    /// happens to be long. Pressure from a long sentence takes whole rows away
    /// instead (see `historyEntries`), which is also what keeps the live row from
    /// being drawn smaller than the lines above it.
    private var historyStack: some View {
        let size = PresentationLayout.fontSize(scale: settings.presentationFontScale)
        return VStack(alignment: .leading, spacing: Self.rowGap) {
            ForEach(historyEntries) { entry in
                HistoryRow(entry: entry, size: size, columnGap: Self.columnGap)
            }
        }
    }

    /// Fades to the right so the rule reads as a boundary rather than a table
    /// border. The far stop is `rule.opacity(0)` rather than `.clear` so the
    /// gradient interpolates within one hue instead of drifting through black.
    private var fadingDivider: some View {
        LinearGradient(
            stops: [
                .init(color: Palette.rule, location: 0),
                .init(color: Palette.rule, location: 0.6),
                .init(color: Palette.rule.opacity(0), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: Self.dividerHeight)
    }

    // MARK: - Live row

    /// **The single utterance the entire live row is drawn from** — source text,
    /// target text, accent colour, column order and both one-shot animations.
    ///
    /// Deriving any part of the row from a *different* utterance is what made the
    /// row show two unrelated sentences: the source column took the live
    /// hypothesis while the target column took `utterances.last`, so while the
    /// guest spoke sentence B the audience read B's Korean beside A's finished
    /// English for the whole of B — and `partials[i].target`, the speculative
    /// translation the pipeline computes and pays for, was never rendered at all.
    /// On a direction change it was worse: the column order came from B while the
    /// target came from A, so an English B landed in the Korean (left) slot and
    /// the row became two English blocks with no Korean anywhere.
    private var live: Utterance? {
        pipeline.store.currentPartial ?? pipeline.store.newestFinalized
    }

    /// What the source column shows. `locked` drives both the colour and whether
    /// the caret is drawn; a hypothesis is the only unlocked source state.
    ///
    /// Deliberately carries no language: anything positional or chromatic must
    /// go through `liveLanguage`, which is latched, and not through the live
    /// utterance's raw `sourceLanguage`, which flips mid-hypothesis.
    private var liveSource: (text: String, locked: Bool)? {
        guard let live else { return nil }
        return (live.sourceText, live.sourceState != .hypothesis)
    }

    /// Which language the live row was spoken in — teal for Korean, amber for
    /// English. Also colours the header's level meter, so the meter tells the
    /// room which direction is being spoken.
    ///
    /// Reads the latch (see `liveLanguageLatch`) only once it has actually
    /// latched, and the live detection until then — so an answer taken from two
    /// or three characters still corrects itself, and only an answer backed by
    /// enough text is held for the rest of the sentence. It decides *both* the
    /// accent and which column each text goes in, so a flip here is not a colour
    /// glitch: it is the two columns swapping sides mid-sentence, which is worth
    /// risking early, while the row is two words long, rather than being wrong
    /// for the whole utterance.
    ///
    /// `latch.latched` rather than `latch != nil`: an unlatched latch is only a
    /// record of the tracking, and reading it would render one frame behind the
    /// detection it is tracking.
    private var liveLanguage: Language {
        guard let live else { return .ko }
        if let latch = liveLanguageLatch, latch.id == live.id, latch.latched {
            return latch.language
        }
        return live.sourceLanguage
    }

    /// What the latch is decided from. A struct rather than the utterance so
    /// `onChange` only wakes for the four facts that can move the decision.
    ///
    /// `letters` is *capped* at the latch threshold, which is what keeps this
    /// from changing on every delta of a long sentence: past the threshold the
    /// count reads the same however much more text arrives, so the sample
    /// compares equal and `onChange` stays asleep.
    private struct LiveLanguageSample: Equatable {
        let id: Int
        let language: Language
        let isHypothesis: Bool
        let letters: Int
    }

    private var liveLanguageSample: LiveLanguageSample? {
        guard let live else { return nil }
        return LiveLanguageSample(
            id: live.id,
            language: live.sourceLanguage,
            isHypothesis: live.sourceState == .hypothesis,
            letters: PresentationLayout.letterCount(
                live.sourceText,
                cappedAt: PresentationLayout.languageLatchLetters))
    }

    /// Adopt a language for the live row, or keep the latched one.
    ///
    /// Adopted on every change until the answer is worth freezing, then held for
    /// as long as that id is still a hypothesis. **Not adopted-once-and-held:**
    /// the first delta of a hypothesis is the shortest and least reliable text
    /// there will ever be, and freezing it swapped the row's columns and accent
    /// for the whole sentence whenever it opened with an acronym, a romanized
    /// name or a number. `PresentationLayout.canLatchLanguage` decides when there
    /// is enough evidence; below it the row keeps self-correcting, and a
    /// hypothesis too short to ever reach it simply never latches.
    ///
    /// Once the utterance is no longer a hypothesis the arbitrated language is
    /// authoritative and replaces the latch even if it disagrees.
    ///
    /// A nil sample (an empty feed) leaves the latch alone: there is nothing to
    /// draw, and clearing it would only mean re-deciding on the next frame.
    private func adoptLiveLanguage(_ sample: LiveLanguageSample?) {
        guard let sample else { return }
        if let latch = liveLanguageLatch, latch.id == sample.id,
           latch.latched, sample.isHypothesis {
            return
        }
        liveLanguageLatch = LiveLanguage(
            id: sample.id,
            language: sample.language,
            latched: PresentationLayout.canLatchLanguage(
                letterCount: sample.letters, isHypothesis: sample.isHypothesis))
    }

    private var liveAccent: Color { Self.accent(for: liveLanguage) }

    private static func accent(for language: Language) -> Color {
        language == .ko ? Palette.accentKO : Palette.accentEN
    }

    private var liveRow: some View {
        let size = PresentationLayout.fontSize(
            scale: settings.presentationFontScale * fit)
        let sourceIsKorean = liveLanguage == .ko
        return HStack(alignment: .top, spacing: Self.columnGap) {
            if sourceIsKorean {
                sourceColumn(size: size, isEnglish: false)
                targetColumn(size: size, isEnglish: true)
            } else {
                targetColumn(size: size, isEnglish: false)
                sourceColumn(size: size, isEnglish: true)
            }
        }
    }

    /// The spoken side. The caret trails the text block on its last baseline;
    /// it is a 3pt rectangle rather than a glyph so its size is exact, which
    /// means it cannot be concatenated into the wrapping `Text` — on a source
    /// line that wraps it therefore sits after the widest line rather than
    /// after the final word. Live hypotheses are short enough that this is
    /// almost always the same place.
    @ViewBuilder
    private func sourceColumn(size: CGFloat, isEnglish: Bool) -> some View {
        let source = liveSource
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            if let source, !source.text.isEmpty {
                Text(source.text)
                    .font(Theme.sans(size: size, weight: .light))
                    .lineSpacing(size * 0.4)
                    .foregroundColor(source.locked
                        ? Palette.lockedSource : Palette.provisional)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Present whenever nothing is locked yet — including an empty room,
            // where a blinking caret is the only "we are live" signal the audience
            // gets. But ONLY while actually capturing: on an idle window it claimed
            // live input that wasn't happening, so a stopped session looked like a
            // running one that had gone silent.
            if pipeline.isListening, !(source?.locked ?? false) {
                BlinkingCaret(color: liveAccent, height: size * 0.9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(FinalRuleOverlay(
            shot: ruleShot, active: isEnglish, accent: liveAccent))
    }

    /// The translated side, rendered word by word out of `SpeculativeText`.
    ///
    /// **Motion treatment — "minimal", chosen deliberately over animated
    /// alternatives.** There is *no* per-word animation when a word commits: it
    /// simply renders in the accent colour from that frame on, and the moving
    /// colour boundary is the entire signal. No per-word fades, blurs, scales
    /// or staggers — at presentation size they read as instability. Two
    /// animations survive: corrected words get a 240ms settle (a silent
    /// rewrite is more confusing than a visible one), and a one-shot rule marks
    /// the translation as final.
    @ViewBuilder
    private func targetColumn(size: CGFloat, isEnglish: Bool) -> some View {
        // `live.target`, never `utterances.last.target`: the target must be the
        // translation of the sentence the source column is showing.
        TargetRun(shot: settleShot, target: live?.target, accent: liveAccent)
            .font(Theme.sans(size: size, weight: .light))
            .lineSpacing(size * 0.4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(FinalRuleOverlay(
                shot: ruleShot, active: isEnglish, accent: liveAccent))
    }

    // MARK: - One-shot animations

    /// Which revision of which utterance wants a settle. A pair rather than a
    /// string so `fireSettle` can compare revisions instead of only identities.
    private struct SettleKey: Equatable {
        let id: Int
        let revision: Int
    }

    /// Changes once per revision that carried corrections. Nil when there is
    /// nothing to settle, which `fireSettle` treats as "do not fire".
    private var settleKey: SettleKey? {
        guard let live, !live.target.correctedIndices.isEmpty else { return nil }
        return SettleKey(id: live.id, revision: live.target.revision)
    }

    /// Play the corrected-word settle once for `key`.
    ///
    /// The memory is load-bearing: `settleKey` returns to an *older* key every
    /// time a hypothesis is aborted, because `live` falls back to
    /// `newestFinalized` — and `SpeculativeText.correctedIndices` is never
    /// cleared, so that older key is still asking to be played. Firing on the
    /// change alone re-ran the 240ms fade over a line that had settled long
    /// before: a rewrite cue on text that was not rewritten, which reads as the
    /// transcript being unstable.
    ///
    /// Compares revisions rather than whole keys because revisions only ever
    /// climb for a given utterance, so "already played at or past this revision"
    /// is the exact test, and each utterance needs one slot to answer it.
    private func fireSettle(for key: SettleKey?) {
        guard let key else { return }
        if let slot = playedSettles.firstIndex(where: { $0.id == key.id }) {
            guard playedSettles[slot].revision < key.revision else { return }
            playedSettles[slot] = key
        } else {
            playedSettles.append(key)
            if playedSettles.count > Self.settleMemory { playedSettles.removeFirst() }
        }
        withAnimation(.easeOut(duration: 0.24)) { settleShot.fire() }
    }

    /// Non-nil exactly when the live row's utterance is the transcript of record
    /// *and* its translation has settled — the moment the rule announces. A
    /// hypothesis is never `.arbitrated`, so a sentence that starts before the
    /// previous translation settles suppresses the rule rather than drawing it
    /// under text it does not belong to.
    private var finalRuleID: Int? {
        guard let live,
              live.sourceState == .arbitrated,
              live.target.settled else { return nil }
        return live.id
    }

    /// Play the rule once for `id`.
    ///
    /// The `ruleUtteranceID` guard is load-bearing, not belt-and-braces:
    /// `finalRuleID` goes id → nil → id whenever a hypothesis starts and is then
    /// discarded without producing an utterance, and `onChange` reports that as a
    /// change. Without the guard the same rule would replay.
    private func fireFinalRule(for id: Int) {
        guard ruleUtteranceID != id else { return }
        ruleUtteranceID = id
        // Linear, with both easing curves applied inside the overlay: one shot
        // carries two different curves (ease-out sweep, then ease-in fade), which
        // a single SwiftUI `Animation` cannot express.
        withAnimation(.linear(duration: FinalRuleOverlay.duration)) {
            ruleShot.fire()
        }
    }

    /// Forget everything keyed by utterance id. Ids restart with the session, so
    /// a remembered id from the previous meeting would otherwise be mistaken for
    /// this meeting's utterance and rob it of its one-shot.
    private func resetSessionMemory() {
        ruleUtteranceID = nil
        playedSettles.removeAll()
        liveLanguageLatch = nil
    }

    // MARK: - Auto-fit

    /// Vertical room the live row may occupy before it starts clipping, or
    /// `.unmeasured` while the feed has yet to report a height.
    ///
    /// **Deliberately not clamped to zero.** It used to be `max(0, …)`, which
    /// fed a genuine "history has taken everything" straight into the layout
    /// rules' "not laid out yet" sentinel: `fittedScale` returned the fit
    /// unchanged, `shouldYieldHistory` was never consulted, history never gave a
    /// row back, and the live row sat clipped for the rest of the sentence with
    /// no escape. A negative room is now reported as measured and negative,
    /// which the rules read as maximum pressure — see `PresentationLayout.Room`.
    ///
    /// `feedHeight > 0` is the laid-out test because it is the container's own
    /// height, unaffected by content, and the first thing SwiftUI reports. The
    /// error it can make is one-sided and harmless: a `historyHeight` lagging by
    /// one pass over-estimates the room, which can only ever mean "no pressure
    /// yet", never a false shrink.
    private var liveRoom: PresentationLayout.Room {
        guard feedHeight > 0 else { return .unmeasured }
        return .measured(feedHeight
            - Self.feedTopPadding - Self.feedBottomPadding
            - Self.dividerHeight - Self.rowGap * 2
            - historyHeight)
    }

    /// The two measurements one fit evaluation reads, bundled so a single
    /// `onChange` watches both: the fit has to re-run when the *room* moves and
    /// not only when the live row's own height does.
    ///
    /// Deliberately measurements only, and not the yield or the fit themselves.
    /// Keying on those too would re-enter before the layout it caused had been
    /// measured, so one overflow would spend its decision against a stale room
    /// and drop every history row at once where one row would have done.
    private struct FitInput: Equatable {
        let contentHeight: CGFloat
        let room: PresentationLayout.Room
    }

    private var fitInput: FitInput {
        FitInput(contentHeight: liveContentHeight, room: liveRoom)
    }

    /// Back to full size. Called for a new utterance, a manual scale change and
    /// a resize — the three events after which any accumulated shrink or yield
    /// is an answer to a question nobody asked any more.
    ///
    /// **This is the only thing that ever raises the fit, and that is on
    /// purpose.** `applyFit` can only lower it, so recovery happens on a genuine
    /// change of input rather than as a step of its own. It is also what keeps
    /// the recovery `grownScale` used to provide: a long sentence that shrank the
    /// text in a small window comes straight back to full size when the window
    /// is enlarged, because a resize moves `feedHeight` and lands here.
    private func resetFit() {
        fit = 1.0
        historyYield = 0
    }

    /// Feed the measured geometry back through the layout rules.
    ///
    /// Escalates in one order and never the other way round: an overflowing live
    /// row first claims a history row, and only once history is drawing nothing
    /// does the live text shrink. That order is what keeps the live row — the
    /// one line the room actually needs — from being set smaller than the
    /// settled lines above it, which is what happened while the depth was a
    /// function of the font scale alone.
    ///
    /// One step per evaluation, because each step changes the very geometry the
    /// next decision is made from.
    ///
    /// **Both escalations are monotone, and that is the entire termination
    /// argument.** The yield only ever rises and is bounded by the depth in
    /// force; the fit only ever falls and is bounded by `minFit`, at most
    /// `PresentationLayout.maxFitSteps` steps away. So for one (utterance, room)
    /// pair this can move the layout at most a dozen times before it reaches a
    /// fixed point, and it cannot cycle, because nothing here hands back what
    /// either escalation took. Recovery is `resetFit`'s job and runs only when an
    /// input genuinely changed.
    ///
    /// That is a replacement for, not a refinement of, the shrink/grow pair this
    /// used to run: a grow step guarded by a percentage-of-height band oscillates
    /// forever as soon as a step changes the *wrapped line count*, which one
    /// projector-sized step routinely does. See `PresentationLayout.fittedScale`.
    private func applyFit(_ input: FitInput) {
        // A room nobody has measured is not pressure. An exhausted one is, even
        // before the live row has reported a height of its own: history alone has
        // already overflowed the feed.
        guard input.contentHeight > 0 || input.room.isExhausted else { return }
        let drawn = historyEntries.count
        if PresentationLayout.shouldYieldHistory(contentHeight: input.contentHeight,
                                                room: input.room,
                                                historyRows: drawn) {
            let depth = PresentationLayout.historyDepth(
                forScale: settings.presentationFontScale,
                rowsYielded: historyYield)
            historyYield += PresentationLayout.yieldStep(depth: depth,
                                                         drawnRows: drawn)
            return
        }
        let next = PresentationLayout.fittedScale(contentHeight: input.contentHeight,
                                                 in: input.room, current: fit)
        // Downward only. `fittedScale` never returns more than `fit`; the
        // comparison says so at the call site too, so a future edit that made it
        // grow would be ignored here rather than quietly starting a loop.
        if fit - next > 0.005 { fit = next }
    }

    /// Reports the height of the view it is attached to (as a `background`, so
    /// it never influences layout). Uses `onChange` rather than a
    /// `PreferenceKey`: `onPreferenceChange`'s action is `@Sendable` in the
    /// current SDK and so cannot touch `@State` without an actor hop.
    private func heightReader(_ report: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.height, initial: true) { _, height in
                    report(height)
                }
        }
    }
}

// MARK: - Palette

/// Exact values from the approved design. File-scoped so the row and control
/// subviews below share them without threading colours through initialisers.
private enum Palette {
    static let background = Color(hex: 0x0C0F12)
    static let headerBackground = Color(hex: 0x0A0D10)
    static let headerHairline = Color(hex: 0x171D22)
    static let rule = Color(hex: 0x23292F)
    static let controlFill = Color(hex: 0x14191E)
    static let controlBorder = Color(hex: 0x232A31)
    static let controlHover = Color(hex: 0x1E252C)
    static let icon = Color(hex: 0x93A1AC)
    static let brand = Color(hex: 0xEFF4F7)
    static let meta = Color(hex: 0x6E7A85)
    static let historyKorean = Color(hex: 0xC7D2DA)
    static let lockedSource = Color(hex: 0xE8EEF2)
    static let provisional = Color(hex: 0x6B7A85)
    static let meterIdle = Color(hex: 0x3A444C)
    /// Accents: teal when Korean was spoken, amber when English was.
    static let accentKO = Color(hex: 0x7FE3C4)
    static let accentEN = Color(hex: 0xFFB86B)
}

// MARK: - Header pieces

/// Seven bars driven by `pipeline.audioLevel`.
///
/// Its own view on purpose: `audioLevel` updates at audio-chunk rate, and with
/// `@Observable` the read has to be confined to the smallest possible body or
/// the entire feed — including text layout — would re-render dozens of times a
/// second.
@MainActor
private struct LevelMeter: View {
    var pipeline: PipelineController
    let accent: Color

    private static let weights: [CGFloat] = [0.35, 0.6, 0.85, 1.0, 0.85, 0.6, 0.35]
    private static let box: CGFloat = 15
    private static let floor: CGFloat = 2

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<Self.weights.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(pipeline.isListening ? accent : Palette.meterIdle)
                    .frame(width: 2, height: height(at: index))
            }
        }
        .frame(height: Self.box, alignment: .bottom)
        .animation(.easeOut(duration: 0.12), value: pipeline.audioLevel)
    }

    private func height(at index: Int) -> CGFloat {
        guard pipeline.isListening else { return Self.floor }
        let level = CGFloat(min(max(pipeline.audioLevel, 0), 1))
        return Self.floor + (Self.box - Self.floor) * level * Self.weights[index]
    }
}

/// A font-size step. Hover fill lives here rather than in a `ButtonStyle` so
/// the 5pt corner radius stays inside the group's 8pt box instead of poking out
/// of it.
private struct StepButton: View {
    let glyph: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: glyph)
                .font(Theme.sans(size: 20, weight: .light))
                .foregroundColor(Palette.icon)
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Palette.controlHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Drawn rather than an SF Symbol so the 12pt triangle is exactly 12pt.
private struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The 3pt caret trailing the live hypothesis.
///
/// Phase comes from wall-clock time via `TimelineView(.animation)` rather than
/// a repeating SwiftUI animation: a repeating animation restarts whenever the
/// surrounding text re-renders, which at STT revision rate looks like a
/// stutter rather than a blink.
private struct BlinkingCaret: View {
    let color: Color
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Rectangle()
                .fill(color)
                .frame(width: 3, height: height)
                .opacity(Self.opacity(at: context.date))
        }
    }

    /// Visible for the first 45% of a 1.1s cycle, hidden from 55% on, with the
    /// 10% between as the fade out.
    private static func opacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1.1) / 1.1
        if phase < 0.45 { return 1 }
        if phase < 0.55 { return 1 - (phase - 0.45) / 0.10 }
        return 0
    }
}

// MARK: - Rows

/// One settled exchange, reduced to what the row draws. Flattening it out of
/// `Utterance` keeps `HistoryRow` free of any main-actor state, so it re-renders
/// without pulling the store into its body.
private struct HistoryEntry: Identifiable {
    let id: Int
    let korean: String
    let english: String
    let accent: Color
    let opacity: Double
}

/// A settled exchange. Korean left, English right, equal columns — the two
/// `maxWidth: .infinity` children split the row evenly, which is what the
/// design's "two-column grid" means here and behaves better with wrapping text
/// than a `Grid` does.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let size: CGFloat
    let columnGap: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: columnGap) {
            column(entry.korean, color: Palette.historyKorean)
            column(entry.english, color: entry.accent)
        }
        .opacity(entry.opacity)
    }

    private func column(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.sans(size: size, weight: .light))
            // SwiftUI's lineSpacing is the *gap*, so 0.4em of leading gives the
            // design's 1.4 line height.
            .lineSpacing(size * 0.4)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - One-shot animations

/// A 0→1 ramp that plays once and needs no reset.
///
/// **Why it is shaped like this.** The obvious spelling of a one-shot cannot
/// work in SwiftUI:
///
///     progress = 0
///     withAnimation(...) { progress = 1 }        // ← never draws
///
/// Both writes land in the same update, `body` runs once at the end of it, and
/// the animation interpolates from the last value SwiftUI actually *rendered*.
/// The intermediate 0 is never presented, so from the renderer's point of view
/// the value went 1 → 1 (or 0 → 0 on the first play) and nothing moves. That is
/// exactly why the rule was invisible for every utterance of every meeting and
/// why corrected words swapped in with no cue at all.
///
/// So `clock` only ever counts *up* — one shot is `clock += 1` — which gives the
/// animation a real interval to interpolate, and `origin` records where the
/// current shot started. `origin` is deliberately **not** animatable: it takes
/// effect immediately, so the first frame of a shot reads `progress == 0`
/// without anything having to be presented first.
///
/// The consumer must conform to `Animatable` with `clock` as its
/// `animatableData` — SwiftUI re-runs the consumer's body once per frame with an
/// interpolated `clock`, which is the only way a value that is *computed into*
/// text colours or scale factors can be animated at all.
private struct OneShot {
    /// Monotonic shot counter; the value an `Animatable` consumer interpolates.
    var clock: Double = 0

    /// `clock` at the start of the current shot. Never interpolated.
    private(set) var origin: Double = 0

    /// 0 at the start of the current shot, 1 at its end.
    var progress: Double { min(max(clock - origin, 0), 1) }

    /// Begin a shot. Call inside `withAnimation`.
    mutating func fire() {
        origin = clock
        clock += 1
    }
}

/// The translated words as one wrapping run, built by `Text` concatenation. An
/// `HStack` of words would not wrap, and a per-word `ForEach` inside a flow
/// layout would re-measure every word on every revision.
///
/// Corrected words fade in through their colour's alpha because `Text` exposes
/// no per-run `opacity` — the visible result is the same settle.
///
/// **`Animatable` is what makes that settle visible.** A per-run colour is baked
/// into the resolved text; it is not an animatable attribute SwiftUI can
/// interpolate on its own, so a `withAnimation` around the progress value would
/// re-run this body exactly once and the corrected word would snap. Conforming
/// here — with the shot's monotonic clock as `animatableData` — makes SwiftUI
/// re-run the body per frame with an interpolated clock, rebuilding the run at
/// each alpha. The cost (one text relayout per frame for 240ms) is the price of
/// not shipping a silent rewrite.
private struct TargetRun: View, Animatable {
    var shot: OneShot
    let target: SpeculativeText?
    let accent: Color

    var animatableData: Double {
        get { shot.clock }
        set { shot.clock = newValue }
    }

    var body: some View { run }

    private var run: Text {
        guard let target, !target.isEmpty else { return Text(verbatim: "") }
        let settle = shot.progress
        var out = Text(verbatim: "")
        for (index, word) in target.words.enumerated() {
            // `effectiveCommittedCount`, not `committedCount`: the raw frontier
            // may legitimately exceed `words.count` across the hypothesis →
            // final boundary, and only the clamped accessor is safe to index by.
            let base = index < target.effectiveCommittedCount
                ? accent : Palette.provisional
            let color = target.correctedIndices.contains(index)
                ? base.opacity(0.35 + 0.65 * settle)
                : base
            out = out + Text(verbatim: index == 0 ? word : " " + word)
                .foregroundColor(color)
        }
        return out
    }
}

/// The "translation is final" rule: 1pt of accent drawn left-to-right beneath
/// the English column, then faded out. A `scaleEffect` from the leading anchor
/// rather than an animated `frame` width so it cannot force a relayout of the
/// text above it mid-animation.
///
/// One `OneShot` drives both halves. The shot is animated *linearly* over
/// `duration` and the two curves are applied here, because the effect is a
/// 350ms ease-out sweep followed by a 650ms ease-in fade — two curves over one
/// timeline, which no single `Animation` value can describe. `Animatable` on the
/// modifier is what gets this body re-run per frame; without it SwiftUI would
/// only interpolate the end-point scale and opacity and the phases would blur
/// into each other.
private struct FinalRuleOverlay: ViewModifier, Animatable {
    /// Total shot length. The sweep owns `growFraction` of it, the fade the rest.
    static let duration: Double = 1.0
    private static let growFraction: Double = 0.35

    var shot: OneShot
    let active: Bool
    let accent: Color

    var animatableData: Double {
        get { shot.clock }
        set { shot.clock = newValue }
    }

    /// Width sweep, ease-out. Reaches full width at `growFraction` and stays.
    private var grow: Double {
        let phase = min(shot.progress / Self.growFraction, 1)
        return 1 - (1 - phase) * (1 - phase)
    }

    /// Opacity, ease-in, starting only once the sweep has finished, and ending
    /// at 0 so a played-out rule leaves nothing behind. Before the first shot
    /// this is 1, but `grow` is 0 there — a zero-width rule — so the overlay is
    /// equally invisible at both ends of the timeline and two consecutive shots
    /// meet with no flash.
    private var fade: Double {
        guard shot.progress > Self.growFraction else { return 1 }
        let phase = (shot.progress - Self.growFraction) / (1 - Self.growFraction)
        return 1 - phase * phase
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomLeading) {
            if active {
                Rectangle()
                    .fill(accent)
                    .frame(height: 1)
                    .scaleEffect(x: grow, anchor: .leading)
                    .opacity(fade)
                    .offset(y: 12)
                    .allowsHitTesting(false)
            }
        }
    }
}
