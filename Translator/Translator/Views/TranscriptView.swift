import SwiftUI
import AppKit

/// Live bilingual transcript with a minimal header: a centered control island
/// (source · Start/Stop · options gear) flanked by the macOS traffic lights on
/// the left and the connection status + live session timer on the right. One
/// row per utterance (timestamp, Korean, English beneath in cyan), and the
/// current partial hypothesis as a gray mutating line pinned at the bottom.
/// Always auto-scrolls to the newest entry on every content change.
struct TranscriptView: View {
    @Bindable var pipeline: PipelineController
    @Bindable var settings: AppSettings
    var onOpenSettings: () -> Void = {}

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = pipeline.lastError {
                errorBanner(error)
            }
            transcript
        }
    }

    // MARK: - Header (centered control island)

    private var header: some View {
        HStack(spacing: 0) {
            // Reserve space on the left for the macOS traffic lights so the
            // island lands on the window's centerline. The right zone matches
            // its width to keep the island truly centered.
            Color.clear.frame(width: sideZoneWidth, height: 1)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                controlIsland
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            statusCluster.frame(width: sideZoneWidth, alignment: .trailing)
        }
        // Sized by padding rather than a fixed height so the island isn't
        // flush with the divider — extra room below it for breathing space.
        .padding(.top, 6)
        .padding(.bottom, 12)
        .padding(.horizontal, 14)
        .background(Theme.glassHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
        .animation(.easeOut(duration: 0.15), value: pipeline.isListening)
    }

    private let sideZoneWidth: CGFloat = 96

    /// The floating capsule: source on the left, the larger Start/Stop button
    /// dead center, the options gear on the right.
    private var controlIsland: some View {
        HStack(spacing: 12) {
            sourceButton
            startStopButton
            gearMenu
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        )
    }

    // MARK: Source (single icon, tap to toggle, right-click for apps)

    private var sourceButton: some View {
        Button(action: toggleSource) {
            Image(systemName: sourceSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sourceHelp)
        .contextMenu { sourceMenuItems }
    }

    private var sourceSymbol: String {
        switch pipeline.audioSource {
        case .microphone: return "mic.fill"
        case .systemAudio, .process: return "speaker.wave.2.fill"
        }
    }

    private var sourceHelp: String {
        switch pipeline.audioSource {
        case .microphone: return "Microphone — click for system audio, right-click for an app"
        case .systemAudio: return "System Audio — click for mic, right-click for a single app"
        case .process(_, let name): return "Capturing \(name) — right-click to change"
        }
    }

    private func toggleSource() {
        pipeline.switchSource(pipeline.audioSource == .microphone ? .systemAudio : .microphone)
    }

    @ViewBuilder
    private var sourceMenuItems: some View {
        Button("Microphone") { pipeline.switchSource(.microphone) }
        Button("All System Audio") { pipeline.switchSource(.systemAudio) }
        let processes = SystemAudioCaptureService.runningAudioProcesses()
        if !processes.isEmpty {
            Divider()
            Text("Capture a single app")
            ForEach(Array(processes.prefix(12).enumerated()), id: \.offset) { _, process in
                Button(process.name) {
                    pipeline.switchSource(.process(pid: process.pid, name: process.name))
                }
            }
        }
    }

    // MARK: Start / Stop (the centered hero)

    private var startStopButton: some View {
        Button(action: { pipeline.toggleListening() }) {
            ZStack {
                Circle().fill(pipeline.isListening
                    ? Color(red: 1.0, green: 0.27, blue: 0.23)
                    : Theme.lime)
                Image(systemName: pipeline.isListening ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(pipeline.isListening ? Color.white : Color.black.opacity(0.85))
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(PressableButtonStyle())
        .help(pipeline.isListening ? "Stop listening" : "Start listening")
    }

    // MARK: Options gear (text size, saved conversations, settings)

    private var gearMenu: some View {
        Menu {
            Section("Text size") {
                Button { adjustFont(+1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                Button { adjustFont(-1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                Button { settings.fontScale = 1.0 } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
            }
            Divider()
            Button { openSavedConversations() } label: {
                Label("Open Saved Conversations", systemImage: "cloud")
            }
            Button { onOpenSettings() } label: {
                Label("Settings…", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Options")
    }

    private func adjustFont(_ direction: Int) {
        settings.fontScale += Double(direction) * AppSettings.fontScaleStep
    }

    /// Opens the cloud session viewer in the default browser.
    private func openSavedConversations() {
        var base = settings.cloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/app") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Status + live timer (right)

    private var statusCluster: some View {
        HStack(spacing: 7) {
            Group {
                if pipeline.isListening {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsedString)
                            .monospacedDigit()
                    }
                } else {
                    Text("Ready")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .shadow(color: statusColor.opacity(pipeline.isListening ? 0.7 : 0), radius: 3)
        }
    }

    private var elapsedString: String {
        guard let start = pipeline.store.sessionStart else { return "0:00" }
        let total = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var statusColor: Color {
        switch pipeline.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .idle: return pipeline.isListening ? .yellow : Color.white.opacity(0.25)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(Theme.mono(size: 10))
            .foregroundColor(.red.opacity(0.9))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12))
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if pipeline.store.utterances.isEmpty && pipeline.store.partials.isEmpty {
                        emptyState
                    }
                    ForEach(pipeline.store.utterances) { utterance in
                        UtteranceRow(
                            utterance: utterance,
                            timeFormatter: Self.timeFormatter,
                            scale: settings.fontScale)
                            .id(utterance.id)
                    }
                    // The current gray hypothesis line, pinned at the bottom.
                    ForEach(pipeline.store.partials) { partial in
                        Text(partial.korean)
                            .font(Theme.sans(size: 15 * settings.fontScale))
                            .foregroundColor(Theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("partial-\(partial.id)")
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            // Keeps the viewport glued to the end as rows grow between the
            // explicit scrollTo calls below — streamed tokens resize rows
            // without firing onChange in the same frame.
            .defaultScrollAnchor(.bottom)
            .onChange(of: pipeline.store.utterances.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: partialsFingerprint) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: englishFingerprint) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Changes whenever the hypothesis text changes.
    private var partialsFingerprint: String {
        pipeline.store.partials.map(\.korean).joined(separator: "\u{1}")
    }

    /// Changes whenever any row's English text grows — cheap proxy for
    /// "streamed content changed the layout height".
    private var englishFingerprint: Int {
        pipeline.store.utterances.reduce(0) { $0 + $1.english.utf8.count }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundColor(Theme.textDim)
            Text(pipeline.isListening
                 ? "Listening — \(pipeline.connectionState.label)"
                 : "Press ▶ Start above to begin")
                .font(Theme.mono(size: 11))
                .foregroundColor(Theme.textMeta)
            if !pipeline.isListening && (!Credentials.hasRTZR || !Credentials.hasAnthropic) {
                Button(action: onOpenSettings) {
                    Text("API keys missing — open Settings (⌘,)")
                        .font(Theme.mono(size: 10))
                        .foregroundColor(.yellow.opacity(0.85))
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

/// Subtle scale + dim on press, matching native control feedback.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct UtteranceRow: View {
    let utterance: Utterance
    let timeFormatter: DateFormatter
    let scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timeFormatter.string(from: utterance.timestamp))
                .font(Theme.mono(size: 10))
                .foregroundColor(Theme.textDim)
            Text(utterance.korean)
                .font(Theme.sans(size: 15 * scale))
                .foregroundColor(Theme.text)
                .textSelection(.enabled)
            if !utterance.english.isEmpty || utterance.state == .translating {
                Text(utterance.english.isEmpty ? "…" : utterance.english)
                    .font(Theme.sans(size: 14 * scale))
                    .foregroundColor(utterance.state == .failed ? .red.opacity(0.8) : Theme.cyan)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
