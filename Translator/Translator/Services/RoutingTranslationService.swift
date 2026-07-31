import Foundation

/// Dispatches each translation to whichever provider Settings currently names.
///
/// The decision is made per *request*, not at construction, and that is the
/// whole point of this type. `PipelineController` holds one `Translating` for
/// the life of the app, with a bounded translation queue hanging off it, so
/// there is no safe moment to swap the object out — rebuilding the pipeline to
/// change provider would drop whatever is in flight. Routing per request means
/// flipping Settings → Translation mid-meeting affects the next utterance and
/// nothing else.
///
/// Both back-ends are constructed eagerly and kept alive: each is little more
/// than a `URLSession`, and holding both means a provider switch doesn't pay
/// TLS setup on the first utterance after the switch — which is precisely the
/// utterance the user is watching to see whether the switch worked.
final class RoutingTranslationService: Translating {
    private let anthropic: Translating
    private let openRouter: Translating
    private let provider: @Sendable () -> TranslationProvider

    init(
        anthropic: Translating = ClaudeTranslationService(),
        openRouter: Translating = OpenRouterTranslationService(),
        provider: @escaping @Sendable () -> TranslationProvider = {
            RoutingTranslationService.storedProvider()
        }
    ) {
        self.anthropic = anthropic
        self.openRouter = openRouter
        self.provider = provider
    }

    func streamTranslation(
        of text: String,
        from source: Language,
        to target: Language,
        context: [TranslationPair],
        forbidSkip: Bool
    ) -> AsyncThrowingStream<String, Error> {
        let choice = provider()
        // Logged per request, not per switch: when a meeting's translations go
        // wrong, the first question is always "which model produced this
        // line?", and the answer has to be reconstructable from the JSONL
        // alone. `forbidSkip` marks the retry pass so a duplicate-looking pair
        // of routed events isn't mistaken for double dispatch.
        DiagnosticLog.shared.info("translate", "routed", [
            "provider": choice.rawValue,
            "model": Self.modelLabel(for: choice),
            "direction": "\(source.rawValue)->\(target.rawValue)",
            "forbid_skip": forbidSkip,
        ])

        switch choice {
        case .anthropic:
            return anthropic.streamTranslation(
                of: text, from: source, to: target,
                context: context, forbidSkip: forbidSkip)
        case .openRouter:
            return openRouter.streamTranslation(
                of: text, from: source, to: target,
                context: context, forbidSkip: forbidSkip)
        }
    }

    // MARK: - Settings reads

    /// The current provider, read straight out of UserDefaults rather than off
    /// `AppSettings.shared`.
    ///
    /// `Translating.streamTranslation` is synchronous and non-isolated, and the
    /// default `provider` closure is `@Sendable` because it may be called from
    /// whatever context the pipeline is on. `AppSettings` is an `@Observable`
    /// reference type and therefore not `Sendable`, so capturing it in a
    /// `@Sendable` closure is a strict-concurrency error. UserDefaults is
    /// thread-safe and holds exactly the same value — `AppSettings` writes this
    /// key on every mutation and registers the default — so reading the raw key
    /// is both correct and isolation-free. Same reasoning as
    /// `TranslationPrompt.system(from:)`, which reads the glossary key
    /// directly for the same reason.
    ///
    /// The key names are duplicated from `AppSettings`, which is the cost of
    /// this approach: they must stay in sync with the `didSet` bodies there.
    static func storedProvider() -> TranslationProvider {
        let raw = UserDefaults.standard.string(forKey: "translationProvider") ?? ""
        return TranslationProvider(rawValue: raw) ?? .anthropic
    }

    /// Human-meaningful model identifier for the diagnostics line. For
    /// Anthropic that is fixed at build time; for OpenRouter it is whatever
    /// slug Settings holds, with the same empty-means-default rule
    /// `OpenRouterTranslationService` applies before sending a request.
    private static func modelLabel(for provider: TranslationProvider) -> String {
        switch provider {
        case .anthropic:
            return ClaudeTranslationService.model
        case .openRouter:
            let slug = (UserDefaults.standard.string(forKey: "openRouterModel") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return slug.isEmpty ? AppSettings.defaultOpenRouterModel : slug
        }
    }
}
