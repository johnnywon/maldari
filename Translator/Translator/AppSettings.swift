import Foundation

/// Shared app settings persisted via UserDefaults
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Window background opacity (0.2 to 1.0). Default 0.9 (90%)
    var windowOpacity: Double {
        didSet { UserDefaults.standard.set(windowOpacity, forKey: "windowOpacity") }
    }

    /// Transcript text-size multiplier (0.8 to 1.6). Default 1.0. Scales the
    /// Korean/English rows and the subtitle panel; adjusted from the header
    /// gear menu or Settings.
    var fontScale: Double {
        didSet {
            let clamped = min(max(fontScale, Self.minFontScale), Self.maxFontScale)
            if clamped != fontScale { fontScale = clamped; return }
            UserDefaults.standard.set(fontScale, forKey: "fontScale")
        }
    }
    static let minFontScale = 0.8
    static let maxFontScale = 1.6
    static let fontScaleStep = 0.1

    /// Keep window floating above other windows
    var alwaysOnTop: Bool {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop") }
    }

    /// Comma-separated RTZR keyword-boost list ("word" or "word:score").
    var keywords: String {
        didSet { UserDefaults.standard.set(keywords, forKey: "rtzrKeywords") }
    }

    /// Default audio source: "microphone" or "system".
    var defaultSourceRaw: String {
        didSet { UserDefaults.standard.set(defaultSourceRaw, forKey: "defaultSource") }
    }

    /// Floating two-line English subtitle panel.
    var subtitleMode: Bool {
        didSet { UserDefaults.standard.set(subtitleMode, forKey: "subtitleMode") }
    }

    /// Where the floating subtitle panel sits: "bottom" (default) or "top".
    var subtitlePositionRaw: String {
        didSet { UserDefaults.standard.set(subtitlePositionRaw, forKey: "subtitlePosition") }
    }
    var subtitleAtTop: Bool { subtitlePositionRaw == "top" }

    /// Subtitle text-size multiplier, independent of the transcript `fontScale`
    /// so on-screen captions can be sized for across-the-room reading.
    var subtitleFontScale: Double {
        didSet {
            let clamped = min(max(subtitleFontScale, Self.minSubtitleScale), Self.maxSubtitleScale)
            if clamped != subtitleFontScale { subtitleFontScale = clamped; return }
            UserDefaults.standard.set(subtitleFontScale, forKey: "subtitleFontScale")
        }
    }
    static let minSubtitleScale = 0.8
    static let maxSubtitleScale = 2.5
    static let subtitleScaleStep = 0.1

    /// Subtitle text color packed as 0xRRGGBB. Defaults to the UI translation
    /// color (Theme.cyan) so captions match the transcript's English rows.
    var subtitleColorHex: Int {
        didSet { UserDefaults.standard.set(subtitleColorHex, forKey: "subtitleColorHex") }
    }
    static let defaultSubtitleColorHex = 0x5CE0D8

    /// Show the English translation line beneath the Korean in subtitles.
    /// Default on (Korean + English); off shows the Korean source only.
    var subtitleShowEnglish: Bool {
        didSet { UserDefaults.standard.set(subtitleShowEnglish, forKey: "subtitleShowEnglish") }
    }

    /// `localizedName` of the display the subtitle panel should use.
    /// Empty string = Automatic (topmost); falls back to topmost when the
    /// named display isn't connected.
    var subtitleDisplayName: String {
        didSet { UserDefaults.standard.set(subtitleDisplayName, forKey: "subtitleDisplayName") }
    }

    // MARK: - Bidirectional capture

    /// How many languages and channels a session runs. See `CaptureMode`.
    /// Global, not Presentation-Mode-only: the transcript window, subtitle
    /// overlay, and Presentation window all render whatever the pipeline
    /// produces, so flipping this mid-app would give three surfaces three
    /// different records of the same meeting.
    var captureModeRaw: String {
        didSet { UserDefaults.standard.set(captureModeRaw, forKey: "captureMode") }
    }
    var captureMode: CaptureMode { CaptureMode(rawValue: captureModeRaw) ?? .koreanOnly }

    /// Translate from the mutating STT hypothesis instead of waiting for a
    /// final. Costs ~5 short calls per utterance instead of 1; the payoff is
    /// translation appearing while the speaker is still talking. Off falls back
    /// to the original translate-on-final behaviour, which is also the escape
    /// hatch if a meeting needs to be cheap or a provider is rate-limiting.
    var speculativeTranslation: Bool {
        didSet { UserDefaults.standard.set(speculativeTranslation, forKey: "speculativeTranslation") }
    }

    // MARK: - Presentation mode

    /// Full-screen, guest-facing bilingual window.
    var presentationMode: Bool {
        didSet { UserDefaults.standard.set(presentationMode, forKey: "presentationMode") }
    }

    /// `localizedName` of the display the Presentation window opens on.
    /// Empty = Automatic (topmost), same rule as the subtitle overlay.
    var presentationDisplayName: String {
        didSet { UserDefaults.standard.set(presentationDisplayName, forKey: "presentationDisplayName") }
    }

    /// Presentation text-size multiplier, independent of both the transcript
    /// `fontScale` and the subtitle scale — a room-facing display is sized for
    /// the far wall, not for the operator.
    var presentationFontScale: Double {
        didSet {
            let clamped = min(max(presentationFontScale, Self.minPresentationScale),
                              Self.maxPresentationScale)
            if clamped != presentationFontScale { presentationFontScale = clamped; return }
            UserDefaults.standard.set(presentationFontScale, forKey: "presentationFontScale")
        }
    }
    static let minPresentationScale = 0.6
    static let maxPresentationScale = 3.2
    static let presentationScaleStep = 0.12

    // MARK: - Translation provider

    /// Which service translates. Anthropic direct is the default: it keeps
    /// prompt caching and one less network hop.
    var translationProviderRaw: String {
        didSet { UserDefaults.standard.set(translationProviderRaw, forKey: "translationProvider") }
    }
    var translationProvider: TranslationProvider {
        TranslationProvider(rawValue: translationProviderRaw) ?? .anthropic
    }

    /// OpenRouter model slug, e.g. "openai/gpt-4o-mini". Only consulted when
    /// `translationProvider == .openRouter`.
    var openRouterModel: String {
        didSet { UserDefaults.standard.set(openRouterModel, forKey: "openRouterModel") }
    }
    static let defaultOpenRouterModel = "openai/gpt-4o-mini"

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
        default: return .microphone
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        defaults.register(defaults: [
            "windowOpacity": 0.9,
            "fontScale": 1.0,
            "alwaysOnTop": true,
            "rtzrKeywords": Self.defaultKeywords,
            "defaultSource": "microphone",
            "subtitleMode": false,
            "subtitlePosition": "bottom",
            "subtitleFontScale": 1.0,
            "subtitleColorHex": Self.defaultSubtitleColorHex,
            "subtitleShowEnglish": true,
            "subtitleDisplayName": "",
            "translationGlossary": Self.defaultGlossary,
            "cloudSyncEnabled": true,
            "cloudEndpoint": Self.defaultCloudEndpoint,
            "captureMode": CaptureMode.koreanOnly.rawValue,
            "speculativeTranslation": true,
            "presentationMode": false,
            "presentationDisplayName": "",
            "presentationFontScale": 1.0,
            "translationProvider": TranslationProvider.anthropic.rawValue,
            "openRouterModel": Self.defaultOpenRouterModel,
        ])

        self.windowOpacity = defaults.double(forKey: "windowOpacity")
        self.fontScale = defaults.double(forKey: "fontScale")
        self.alwaysOnTop = defaults.bool(forKey: "alwaysOnTop")
        self.keywords = defaults.string(forKey: "rtzrKeywords") ?? Self.defaultKeywords
        self.defaultSourceRaw = defaults.string(forKey: "defaultSource") ?? "microphone"
        self.subtitleMode = defaults.bool(forKey: "subtitleMode")
        self.subtitlePositionRaw = defaults.string(forKey: "subtitlePosition") ?? "bottom"
        self.subtitleFontScale = defaults.double(forKey: "subtitleFontScale")
        self.subtitleColorHex = defaults.integer(forKey: "subtitleColorHex")
        self.subtitleShowEnglish = defaults.bool(forKey: "subtitleShowEnglish")
        self.subtitleDisplayName = defaults.string(forKey: "subtitleDisplayName") ?? ""
        self.glossary = defaults.string(forKey: "translationGlossary") ?? Self.defaultGlossary
        self.cloudSyncEnabled = defaults.bool(forKey: "cloudSyncEnabled")
        self.cloudEndpoint = defaults.string(forKey: "cloudEndpoint") ?? Self.defaultCloudEndpoint
        self.captureModeRaw = defaults.string(forKey: "captureMode") ?? CaptureMode.koreanOnly.rawValue
        self.speculativeTranslation = defaults.bool(forKey: "speculativeTranslation")
        self.presentationMode = defaults.bool(forKey: "presentationMode")
        self.presentationDisplayName = defaults.string(forKey: "presentationDisplayName") ?? ""
        self.presentationFontScale = defaults.double(forKey: "presentationFontScale")
        self.translationProviderRaw =
            defaults.string(forKey: "translationProvider") ?? TranslationProvider.anthropic.rawValue
        self.openRouterModel = defaults.string(forKey: "openRouterModel") ?? Self.defaultOpenRouterModel
    }
}
