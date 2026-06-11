import Foundation

/// Shared app settings persisted via UserDefaults
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Window background opacity (0.2 to 1.0). Default 0.9 (90%)
    var windowOpacity: Double {
        didSet { UserDefaults.standard.set(windowOpacity, forKey: "windowOpacity") }
    }

    /// Keep window floating above other windows
    var alwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop") }
    }

    /// Comma-separated RTZR keyword-boost list ("word" or "word:score").
    var keywords: String {
        didSet { UserDefaults.standard.set(keywords, forKey: "rtzrKeywords") }
    }

    /// Default audio source: "microphone", "system", or "dual" (mic + system
    /// with Me/Them speaker attribution).
    var defaultSourceRaw: String {
        didSet { UserDefaults.standard.set(defaultSourceRaw, forKey: "defaultSource") }
    }

    /// Floating two-line English subtitle panel.
    var subtitleMode: Bool {
        didSet { UserDefaults.standard.set(subtitleMode, forKey: "subtitleMode") }
    }

    /// Domain glossary appended to the translation system prompt — names,
    /// products, and required renderings specific to YOUR meetings. Stored in
    /// defaults (not code) so company-specific vocabulary never ships in the
    /// public repo.
    var glossary: String {
        didSet { UserDefaults.standard.set(glossary, forKey: "translationGlossary") }
    }

    /// Maldari cloud sync: every session uploads to your own Worker as
    /// markdown. The bearer token lives in the Keychain, not here.
    var cloudSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(cloudSyncEnabled, forKey: "cloudSyncEnabled") }
    }

    var cloudEndpoint: String {
        didSet { UserDefaults.standard.set(cloudEndpoint, forKey: "cloudEndpoint") }
    }

    static let defaultKeywords = ""
    static let defaultGlossary = """
        광고비 = ad spend, 수수료 = take rate, 정산 = settlement, \
        입점 = marketplace onboarding, 풀필먼트 = fulfillment. \
        ACV, GMV, ROAS, TACoS and similar metrics pass through as-is.
        """
    static let defaultCloudEndpoint = "https://maldari.johnnywon.com"

    var keywordList: [String] {
        keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var defaultSource: AudioSourceSelection {
        switch defaultSourceRaw {
        case "system": return .systemAudio
        case "dual": return .dual
        default: return .microphone
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        defaults.register(defaults: [
            "windowOpacity": 0.9,
            "alwaysOnTop": true,
            "rtzrKeywords": Self.defaultKeywords,
            "defaultSource": "microphone",
            "subtitleMode": false,
            "translationGlossary": Self.defaultGlossary,
            "cloudSyncEnabled": true,
            "cloudEndpoint": Self.defaultCloudEndpoint,
        ])

        self.windowOpacity = defaults.double(forKey: "windowOpacity")
        self.alwaysOnTop = defaults.bool(forKey: "alwaysOnTop")
        self.keywords = defaults.string(forKey: "rtzrKeywords") ?? Self.defaultKeywords
        self.defaultSourceRaw = defaults.string(forKey: "defaultSource") ?? "microphone"
        self.subtitleMode = defaults.bool(forKey: "subtitleMode")
        self.glossary = defaults.string(forKey: "translationGlossary") ?? Self.defaultGlossary
        self.cloudSyncEnabled = defaults.bool(forKey: "cloudSyncEnabled")
        self.cloudEndpoint = defaults.string(forKey: "cloudEndpoint") ?? Self.defaultCloudEndpoint
    }
}
