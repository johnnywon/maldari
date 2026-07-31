import Foundation

/// Typed access to the API credentials, stored as Keychain generic passwords
/// under one service.
enum Credentials {
    private static let service = "com.translator.app.credentials"

    enum Key: String, CaseIterable {
        case rtzrClientID = "rtzr_client_id"
        case rtzrClientSecret = "rtzr_client_secret"
        case anthropicAPIKey = "anthropic_api_key"
        case maldariUploadToken = "maldari_upload_token"
        /// OpenAI, for the Realtime transcription WebSocket. Deliberately
        /// separate from OpenRouter: OpenRouter is a chat-completions router
        /// with no realtime audio endpoint, so bidirectional capture needs a
        /// direct OpenAI key.
        case openAIAPIKey = "openai_api_key"
        /// OpenRouter, for translation only.
        case openRouterAPIKey = "openrouter_api_key"
    }

    static func get(_ key: Key) -> String? {
        KeychainHelper.load(service: service, account: key.rawValue)
    }

    static func set(_ value: String, for key: Key) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(service: service, account: key.rawValue)
        } else {
            KeychainHelper.save(trimmed, service: service, account: key.rawValue)
        }
    }

    static var hasRTZR: Bool {
        Self.get(.rtzrClientID) != nil && Self.get(.rtzrClientSecret) != nil
    }

    static var hasAnthropic: Bool {
        Self.get(.anthropicAPIKey) != nil
    }

    static var hasOpenAI: Bool {
        Self.get(.openAIAPIKey) != nil
    }

    static var hasOpenRouter: Bool {
        Self.get(.openRouterAPIKey) != nil
    }

    /// Whether the credentials a given capture mode needs are all present.
    /// Bidirectional modes are unusable without an OpenAI key — RTZR only runs
    /// a Korean model, so there is nothing to transcribe English with.
    static func satisfies(_ mode: CaptureMode) -> Bool {
        switch mode {
        case .koreanOnly: return hasRTZR
        case .bidirectionalSingle, .bidirectionalDual: return hasRTZR && hasOpenAI
        }
    }
}
