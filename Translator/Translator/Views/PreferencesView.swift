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

            CloudTab(settings: settings)
                .tabItem { Label("Cloud", systemImage: "icloud") }
        }
        .frame(width: 520, height: 460)
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

                    Toggle("Subtitle mode (floating English captions)", isOn: $settings.subtitleMode)
                        .font(.headline)
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .padding()
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
    @State private var rtzrTest: TestState = .idle
    @State private var anthropicTest: TestState = .idle

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

    var body: some View {
        Form {
            Section("Default audio source") {
                Picker("Source", selection: $settings.defaultSourceRaw) {
                    Text("Microphone").tag("microphone")
                    Text("System Audio").tag("system")
                    Text("Mic + System").tag("dual")
                }
                .pickerStyle(.segmented)
                Text("Mic + System runs both captures at once and labels each line — Me (your mic) or Them (meeting audio).")
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

            Section("Translation glossary") {
                TextEditor(text: $settings.glossary)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 64)
                Text("Required renderings appended to the translation prompt, e.g. 우리회사 = OurCo, 정산 = settlement.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
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
