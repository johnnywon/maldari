import SwiftUI

/// Live bilingual transcript with in-window controls: header (status dot,
/// source picker, Start/Stop, export, settings), one row per utterance
/// (timestamp, Korean, English beneath in cyan), and the current partial
/// hypothesis as a gray mutating line pinned at the bottom. Always
/// auto-scrolls to the newest entry on every content change.
struct TranscriptView: View {
    @Bindable var pipeline: PipelineController
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

    // MARK: - Header controls

    private var header: some View {
        HStack(spacing: 10) {
            // Status indicator (read-only): dot goes yellow while connecting,
            // green once live, red on error.
            statusBadge

            Spacer(minLength: 8)

            sourceToggle
            startStopButton
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        // The panel uses fullSizeContentView, so the traffic lights occupy
        // the top-left ~28pt; the controls row sits below them while the
        // glass background spans the full header.
        .padding(.top, 28)
        .background(Theme.glassHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .animation(.easeOut(duration: 0.15), value: pipeline.audioSource)
        .animation(.easeOut(duration: 0.15), value: pipeline.isListening)
    }

    private var statusBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(pipeline.isListening ? 0.7 : 0), radius: 3)
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        switch pipeline.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .idle: return pipeline.isListening ? .yellow : Color.white.opacity(0.25)
        }
    }

    private var statusText: String {
        if !pipeline.isListening, case .idle = pipeline.connectionState {
            return "Ready"
        }
        return pipeline.connectionState.label
    }

    /// Mic / system-audio / dual segmented toggle. Right-click the speaker
    /// segment to capture a specific app instead of all system audio.
    private var sourceToggle: some View {
        HStack(spacing: 2) {
            sourceSegment(
                symbol: "mic.fill",
                isSelected: pipeline.audioSource == .microphone,
                help: "Microphone"
            ) { pipeline.switchSource(.microphone) }

            sourceSegment(
                symbol: "speaker.wave.2.fill",
                isSelected: pipeline.audioSource != .microphone && pipeline.audioSource != .dual,
                help: systemSegmentHelp
            ) { pipeline.switchSource(.systemAudio) }
                .contextMenu {
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

            sourceSegment(
                symbol: "person.2.fill",
                isSelected: pipeline.audioSource == .dual,
                help: "Mic + System — labels lines Me (mic) / Them (system audio)"
            ) { pipeline.switchSource(.dual) }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }

    private var systemSegmentHelp: String {
        if case .process(_, let name) = pipeline.audioSource {
            return "Capturing \(name) — right-click to change"
        }
        return "System Audio — right-click to capture a single app"
    }

    private func sourceSegment(
        symbol: String, isSelected: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 38, height: 24)
                .background(Capsule().fill(isSelected ? Color.white.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var startStopButton: some View {
        Button(action: { pipeline.toggleListening() }) {
            HStack(spacing: 6) {
                Image(systemName: pipeline.isListening ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(pipeline.isListening ? "Stop" : "Start")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(pipeline.isListening ? Color.white : Color.black.opacity(0.85))
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(
                Capsule().fill(pipeline.isListening
                    ? Color(red: 1.0, green: 0.27, blue: 0.23)
                    : Theme.lime)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help(pipeline.isListening ? "Stop listening" : "Start listening")
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
                        UtteranceRow(utterance: utterance, timeFormatter: Self.timeFormatter)
                            .id(utterance.id)
                    }
                    // One gray hypothesis line per live channel (two when Me
                    // and Them are talking over each other in dual mode).
                    ForEach(pipeline.store.partials) { partial in
                        Text(partialPrefix(partial) + partial.korean)
                            .font(Theme.sans(size: 15))
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

    private func partialPrefix(_ partial: Utterance) -> String {
        partial.speaker.map { "\($0.label) · " } ?? ""
    }

    /// Changes whenever any channel's hypothesis text changes.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(timeFormatter.string(from: utterance.timestamp))
                    .font(Theme.mono(size: 10))
                    .foregroundColor(Theme.textDim)
                if let speaker = utterance.speaker {
                    Text(speaker.label)
                        .font(Theme.mono(size: 9, weight: .semibold))
                        .foregroundColor(speakerColor(speaker))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(speakerColor(speaker).opacity(0.12)))
                }
            }
            Text(utterance.korean)
                .font(Theme.sans(size: 15))
                .foregroundColor(Theme.text)
                .textSelection(.enabled)
            if !utterance.english.isEmpty || utterance.state == .translating {
                Text(utterance.english.isEmpty ? "…" : utterance.english)
                    .font(Theme.sans(size: 14))
                    .foregroundColor(utterance.state == .failed ? .red.opacity(0.8) : Theme.cyan)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speakerColor(_ speaker: Speaker) -> Color {
        speaker == .me ? Theme.lime : Theme.cyan
    }
}
