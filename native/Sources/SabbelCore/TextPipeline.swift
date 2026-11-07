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
    private let previewStages: [Stage]

    /// - Parameter preview: the stages for the live text during a take; none by default.
    public init(_ stages: [Stage] = [], preview: [Stage] = []) {
        self.stages = stages
        previewStages = preview
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
        // The live text gets the stages that change words, quietly: it is
        // rewritten several times a second. The per-app rules wait for the end,
        // or every settled sentence would lose its full stop on the way.
        var preview: [Stage] = [{ text, _ in glossary.apply(text, quiet: true) }]
        if settings.voiceCommands { preview.append(VoiceCommands.stage) }
        if settings.tidyText { preview.append({ text, _ in TextTidy.tidy(text).text }) }
        return TextPipeline(stages, preview: preview)
    }

    public func process(_ text: String, target: FocusTarget?) -> String {
        stages.reduce(text) { text, stage in stage(text, target) }
    }

    /// The settled live text as the paste will roughly read: glossary, voice
    /// commands and tidy-up, without logging.
    public func preview(_ text: String, target: FocusTarget?) -> String {
        previewStages.reduce(text) { text, stage in stage(text, target) }
    }
}
