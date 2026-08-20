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

    /// Fetches the SECRET. Only call this when a request is actually being made —
    /// never from a SwiftUI body or the launch path. See `has(_:)`.
    static func get(_ key: Key) -> String? {
        KeychainHelper.load(service: service, account: key.rawValue)
    }

    /// Whether a key is configured, WITHOUT decrypting it.
    ///
    /// This is what every `has*` below uses, and the distinction is the difference
    /// between an app that launches and one that doesn't: a data-returning keychain
    /// read from a binary the item's ACL no longer trusts blocks the calling thread
    /// behind a modal system dialog, and `has*` is read from view bodies on the main
    /// thread while the windows are being built. See `KeychainHelper.exists`.
    static func has(_ key: Key) -> Bool {
        KeychainHelper.exists(service: service, account: key.rawValue)
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
        Self.has(.rtzrClientID) && Self.has(.rtzrClientSecret)
    }

    static var hasAnthropic: Bool { Self.has(.anthropicAPIKey) }
    static var hasOpenAI: Bool { Self.has(.openAIAPIKey) }
    static var hasOpenRouter: Bool { Self.has(.openRouterAPIKey) }

    /// Whether the credentials a given capture mode needs are all present.
    ///
    /// Bidirectional modes need an OpenAI key: RTZR runs a Korean-only model, so
    /// OpenAI Realtime is the only English engine. (An on-device Apple recognizer
    /// exists in the tree as an alternative but is deliberately not used.)
    static func satisfies(_ mode: CaptureMode) -> Bool {
        switch mode {
        case .koreanOnly: return hasRTZR
        case .bidirectionalSingle, .bidirectionalDual: return hasRTZR && hasOpenAI
        }
    }
}
