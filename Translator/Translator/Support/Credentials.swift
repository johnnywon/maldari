import Foundation

/// Typed access to the three API credentials, stored as Keychain generic
/// passwords under one service.
enum Credentials {
    private static let service = "com.translator.app.credentials"

    enum Key: String, CaseIterable {
        case rtzrClientID = "rtzr_client_id"
        case rtzrClientSecret = "rtzr_client_secret"
        case anthropicAPIKey = "anthropic_api_key"
        case maldariUploadToken = "maldari_upload_token"
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
}
