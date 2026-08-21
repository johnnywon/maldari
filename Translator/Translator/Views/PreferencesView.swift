import AppKit
import SwiftUI

/// Preferences window content — accessible from Maldari menu > Settings (Cmd+,)
struct PreferencesView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gear") }

            APIKeysTab()
                .tabItem { Label("API Keys", systemImage: "key") }

            TranscriptionTab(settings: settings)
                .tabItem { Label("Transcription", systemImage: "waveform") }

            TranslationTab(settings: settings)
                .tabItem { Label("Translation", systemImage: "character.bubble") }

            CloudTab(settings: settings)
                .tabItem { Label("Cloud", systemImage: "icloud") }
        }
        .frame(width: 560, height: 520)
        // Settings is dark-only, regardless of the system appearance.
        .preferredColorScheme(.dark)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Window Opacity")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(settings.windowOpacity * 100))%")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Slider(value: $settings.windowOpacity, in: 0.2...1.0, step: 0.05) {
                            Text("Opacity")
                        } minimumValueLabel: {
                            Text("20%").font(.caption).foregroundColor(.secondary)
                        } maximumValueLabel: {
                            Text("100%").font(.caption).foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    Toggle("Keep window floating above other windows", isOn: $settings.alwaysOnTop)
                        .font(.headline)
                }
                .padding()
            }

            Section("Presentation mode") {
                Toggle("Full-screen bilingual window for the room", isOn: $settings.presentationMode)
                    .font(.headline)
                Text("Korean and English side by side, sized for a meeting room. "
                     + "Turning this on switches Subtitle Mode off — two caption "
                     + "surfaces on one screen is noise. ⌘P from the menu bar.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    DisplayPicker(title: "Display", selection: $settings.presentationDisplayName)

                    HStack {
                        Text("Text size")
                        Spacer()
                        Text("\(Int(settings.presentationFontScale * 100))%")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $settings.presentationFontScale,
                           in: AppSettings.minPresentationScale...AppSettings.maxPresentationScale,
                           step: AppSettings.presentationScaleStep)
                    Text("Also adjustable with − / + in the Presentation window header. "
                         + "Fewer history lines show as the text grows, so the current "
                         + "sentence always has room.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 16)
                .disabled(!settings.presentationMode)
                .opacity(settings.presentationMode ? 1 : 0.5)
            }

            Section("Subtitle mode") {
                Toggle("Floating captions overlay", isOn: $settings.subtitleMode)
                    .font(.headline)
                    .disabled(settings.presentationMode)

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Position", selection: $settings.subtitlePositionRaw) {
                        Text("Bottom").tag("bottom")
                        Text("Top").tag("top")
                    }
                    .pickerStyle(.segmented)

                    DisplayPicker(title: "Display", selection: $settings.subtitleDisplayName)

                    HStack {
                        Text("Caption size")
                        Spacer()
                        Text("\(Int(settings.subtitleFontScale * 100))%")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $settings.subtitleFontScale,
                           in: AppSettings.minSubtitleScale...AppSettings.maxSubtitleScale,
                           step: AppSettings.subtitleScaleStep)

                    Toggle("Show English translation", isOn: $settings.subtitleShowEnglish)
                    Text("Korean always shows in white; English appears below it.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ColorPicker("English text color", selection: Binding(
                        get: { Color(hex: UInt(settings.subtitleColorHex & 0xFFFFFF)) },
                        set: { settings.subtitleColorHex = Int($0.rgbHex) }
                    ), supportsOpacity: false)
                    .disabled(!settings.subtitleShowEnglish)
                }
                .padding(.leading, 16)
                .disabled(!settings.subtitleMode)
                .opacity(settings.subtitleMode ? 1 : 0.5)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// Display picker shared by subtitle and presentation settings — same rule
/// (empty string = automatic/topmost), same handling of a remembered display
/// that is currently unplugged.
private struct DisplayPicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Automatic (topmost)").tag("")
            ForEach(NSScreen.screens, id: \.self) { screen in
                Text(screen.localizedName).tag(screen.localizedName)
            }
            // Keep a remembered-but-disconnected choice selectable.
            if !selection.isEmpty,
               !NSScreen.screens.contains(where: { $0.localizedName == selection }) {
                Text("\(selection) (not connected)").tag(selection)
            }
        }
    }
}

// MARK: - API Keys Tab

private enum TestState: Equatable {
    case idle, testing, ok, failed(String)
}

private struct APIKeysTab: View {
    @State private var rtzrID = Credentials.get(.rtzrClientID) ?? ""
    @State private var rtzrSecret = Credentials.get(.rtzrClientSecret) ?? ""
    @State private var anthropicKey = Credentials.get(.anthropicAPIKey) ?? ""
    @State private var openAIKey = Credentials.get(.openAIAPIKey) ?? ""
    @State private var openRouterKey = Credentials.get(.openRouterAPIKey) ?? ""
    @State private var rtzrTest: TestState = .idle
    @State private var anthropicTest: TestState = .idle
    @State private var openAITest: TestState = .idle
    @State private var openRouterTest: TestState = .idle

    var body: some View {
        Form {
            Section("RTZR (Korean speech-to-text)") {
                TextField("Client ID", text: $rtzrID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: rtzrID) { Credentials.set(rtzrID, for: .rtzrClientID) }
                SecureField("Client Secret", text: $rtzrSecret)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: rtzrSecret) { Credentials.set(rtzrSecret, for: .rtzrClientSecret) }
                testRow(state: rtzrTest, disabled: rtzrID.isEmpty || rtzrSecret.isEmpty) {
                    rtzrTest = .testing
                    Task {
                        do {
                            try await RTZRStreamingService.authenticate(
                                clientID: rtzrID, clientSecret: rtzrSecret)
                            rtzrTest = .ok
                        } catch {
                            rtzrTest = .failed(error.localizedDescription)
                        }
                    }
                }
            }

            Section("Anthropic (Claude Haiku translation)") {
                SecureField("sk-ant-…", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: anthropicKey) { Credentials.set(anthropicKey, for: .anthropicAPIKey) }
                testRow(state: anthropicTest, disabled: anthropicKey.isEmpty) {
                    anthropicTest = .testing
                    Task {
                        do {
                            try await ClaudeTranslationService.testAPIKey(anthropicKey)
                            anthropicTest = .ok
                        } catch {
                            anthropicTest = .failed(error.localizedDescription)
                        }
                    }
                }
            }

            Section("OpenAI (English speech-to-text)") {
                SecureField("sk-…", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: openAIKey) { Credentials.set(openAIKey, for: .openAIAPIKey) }
                testRow(state: openAITest, disabled: openAIKey.isEmpty) {
                    openAITest = .testing
                    Task {
                        do {
                            try await OpenAIRealtimeSTTService.testAPIKey(openAIKey)
                            openAITest = .ok
                        } catch {
                            openAITest = .failed(error.localizedDescription)
                        }
                    }
                }
                Text("Required for bidirectional capture. RTZR only runs a Korean "
                     + "model, so English needs its own engine. This must be a direct "
                     + "OpenAI key — OpenRouter has no realtime audio endpoint and "
                     + "cannot stand in for it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("OpenRouter (optional translation provider)") {
                SecureField("sk-or-…", text: $openRouterKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: openRouterKey) {
                        Credentials.set(openRouterKey, for: .openRouterAPIKey)
                    }
                testRow(state: openRouterTest, disabled: openRouterKey.isEmpty) {
                    openRouterTest = .testing
                    Task {
                        do {
                            try await OpenRouterTranslationService.testAPIKey(openRouterKey)
                            openRouterTest = .ok
                        } catch {
                            openRouterTest = .failed(error.localizedDescription)
                        }
                    }
                }
                Text("Only needed if you switch the translation provider on the "
                     + "Translation tab. Translation only — not speech.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private func testRow(state: TestState, disabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button("Test Connection", action: action)
                .disabled(disabled || state == .testing)
            switch state {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
            case .ok:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.caption)
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundColor(.red).font(.caption)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Transcription Tab

private struct TranscriptionTab: View {
    @Bindable var settings: AppSettings

    private var openAIMissing: Bool { !Credentials.hasOpenAI }

    var body: some View {
        Form {
            Section("Capture mode") {
                Picker("Mode", selection: $settings.captureModeRaw) {
                    ForEach(CaptureMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.captureMode.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if settings.captureMode.isBidirectional && openAIMissing {
                    Label("Needs an OpenAI API key — add it on the API Keys tab.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
                if settings.captureMode.isBidirectional {
                    Text("Both speech engines run on the audio at once and the better "
                         + "transcript wins per sentence. Roughly triples the running "
                         + "cost of a meeting.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Default audio source") {
                Text("Microphone is your own voice. System audio is what your Mac plays, "
                     + "including the other people on a call. Pick a single app instead "
                     + "from the menu bar or the transcript panel.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Source", selection: $settings.defaultSourceRaw) {
                    Text("Microphone").tag("microphone")
                    Text("System audio").tag("system")
                }
                .pickerStyle(.segmented)
            }

            Section("Transcript text size") {
                HStack {
                    Text("Size")
                    Spacer()
                    Text("\(Int(settings.fontScale * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.fontScale,
                       in: AppSettings.minFontScale...AppSettings.maxFontScale,
                       step: AppSettings.fontScaleStep)
                Text("Also adjustable from the header gear menu.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Keyword boosting") {
                TextEditor(text: $settings.keywords)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 64)
                Text("Comma-separated vocabulary hints sent to RTZR — your company, product, and people names. Use word or word:score (score -5.0…5.0, max 100 words, ≤20 chars each).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Translation Tab

private struct TranslationTab: View {
    @Bindable var settings: AppSettings

    @State private var models: [OpenRouterTranslationService.Model] = []
    @State private var loadingModels = false
    @State private var modelError: String?
    @State private var filter = ""

    private var filtered: [OpenRouterTranslationService.Model] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.id.lowercased().contains(query) || $0.name.lowercased().contains(query)
        }
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Translate with", selection: $settings.translationProviderRaw) {
                    ForEach(TranslationProvider.allCases, id: \.rawValue) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Anthropic direct is the default: it keeps prompt caching, which "
                     + "is most of why an hour-long meeting costs cents, and avoids an "
                     + "extra network hop on every speculative pass.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if settings.translationProvider == .openRouter {
                Section("OpenRouter model") {
                    HStack {
                        TextField("Model slug", text: $settings.openRouterModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button(loadingModels ? "Loading…" : "Load models") { loadModels() }
                            .disabled(loadingModels || !Credentials.hasOpenRouter)
                    }
                    if let modelError {
                        Label(modelError, systemImage: "xmark.circle.fill")
                            .font(.caption).foregroundColor(.red).lineLimit(2)
                    }
                    if !models.isEmpty {
                        TextField("Filter", text: $filter)
                            .textFieldStyle(.roundedBorder)
                        // A plain scrolling list rather than a Picker: OpenRouter
                        // serves hundreds of models and a popup menu that long is
                        // unusable.
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(filtered) { model in
                                    ModelRow(
                                        model: model,
                                        selected: model.id == settings.openRouterModel
                                    ) {
                                        settings.openRouterModel = model.id
                                    }
                                }
                            }
                        }
                        .frame(height: 160)
                        .background(Color.black.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("\(filtered.count) of \(models.count) models. Pick something "
                             + "fast — a speculative pass fires several times per "
                             + "sentence, so latency matters more than raw quality.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("Speculative translation") {
                Toggle("Translate while the speaker is still talking",
                       isOn: $settings.speculativeTranslation)
                Text("Fires several short passes per sentence and shows a word as "
                     + "settled once two consecutive passes agree on it. Off falls "
                     + "back to translating once, after the sentence ends — cheaper, "
                     + "and the escape hatch if a provider is rate-limiting you.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Translation glossary") {
                TextEditor(text: $settings.glossary)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 64)
                Text("Required renderings appended to the translation prompt, e.g. "
                     + "우리회사 = OurCo, 정산 = settlement. Applied in both directions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func loadModels() {
        loadingModels = true
        modelError = nil
        Task {
            do {
                models = try await OpenRouterTranslationService.fetchModels()
            } catch {
                modelError = error.localizedDescription
            }
            loadingModels = false
        }
    }
}

private struct ModelRow: View {
    let model: OpenRouterTranslationService.Model
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .font(.system(size: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.id)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                    if let price = model.promptPrice {
                        Text(String(format: "$%.2f / 1M in", price))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear)
    }
}

// MARK: - Cloud Tab

private struct CloudTab: View {
    @Bindable var settings: AppSettings
    @State private var uploadToken = Credentials.get(.maldariUploadToken) ?? ""

    var body: some View {
        Form {
            Section("Maldari cloud sync") {
                Toggle("Save every session to my Maldari site", isOn: $settings.cloudSyncEnabled)
                TextField("Endpoint", text: $settings.cloudEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                SecureField("Upload token", text: $uploadToken)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: uploadToken) {
                        Credentials.set(uploadToken, for: .maldariUploadToken)
                    }
                Text("Transcripts upload as dated markdown to \(settings.cloudEndpoint)/app — readable from anywhere after login. The token matches the Worker's UPLOAD_TOKEN secret.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
