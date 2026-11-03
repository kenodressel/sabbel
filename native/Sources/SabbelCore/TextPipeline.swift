/// Rewrites a take's final text before it is pasted and saved: the glossary,
/// the voice commands, the tidy-up and the per-app rules each add one stage.
///
/// Stages are pure functions of the text and the app the take started in, so
/// the whole chain is testable without a model or AppKit. They run in order on
/// the paste line, after the final recognition and before the injector.
public struct TextPipeline: Sendable {
    /// One rewrite step. `target` is the app frontmost at key-down, or nil.
    public typealias Stage = @Sendable (_ text: String, _ target: FocusTarget?) -> String

    private let stages: [Stage]

    public init(_ stages: [Stage] = []) {
        self.stages = stages
    }

    /// Leaves every text as it is.
    public static let identity = TextPipeline()

    /// The app's pipeline, in this order: glossary, voice commands, tidy-up, per-app rules.
    /// The glossary comes first so the later stages see the corrected terms.
    public static func standard(settings: SabbelSettings, paths: SabbelPaths,
                                log: @escaping @Sendable (String) -> Void) -> TextPipeline {
        let glossary = GlossaryStage(url: paths.glossary, log: log)
        var stages: [Stage] = [{ text, _ in glossary.apply(text) }]
        if settings.voiceCommands { stages.append(VoiceCommands.stage) }
        if settings.tidyText { stages.append(TextTidy.stage(log: log)) }
        if settings.appRules { stages.append(AppRules.stage) }
        return TextPipeline(stages)
    }

    public func process(_ text: String, target: FocusTarget?) -> String {
        stages.reduce(text) { text, stage in stage(text, target) }
    }
}
