import Foundation

/// Configuration for the single user-defined text transformation action.
/// All fields persist in UserDefaults; the AI Builder token stays in Keychain
/// and is never stored here.
struct CustomActionConfig: Equatable, Codable {
    var actionName: String
    var instructions: String
    /// Model id sent to AI Builder Space. V1 lets the user pick between a
    /// small fixed set (see `CustomActionModel.choices`); older configs that
    /// predate this field default to DeepSeek V4 Flash.
    var modelId: String

    var trimmedActionName: String {
        actionName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedInstructions: String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A config is usable only when the action name, instructions, and a
    /// known model id are all non-empty after trimming.
    var isConfigured: Bool {
        !trimmedActionName.isEmpty
            && !trimmedInstructions.isEmpty
            && CustomActionModel.choices.contains(where: { $0.id == modelId })
    }

    static let defaultActionName = "Polish"
    static let defaultInstructions = """
    Rewrite the transcript for clarity. Remove filler and repeated phrases, \
    add paragraph breaks where useful, and preserve the original meaning, \
    language, tone, and level of detail. Return only the revised text.
    """

    /// Localized default config. Called at init time when no saved config
    /// exists; once the user edits and persists, their choice is kept
    /// regardless of language changes.
    static func localizedDefault(for language: AppLanguage) -> CustomActionConfig {
        switch language {
        case .simplifiedChinese:
            return CustomActionConfig(
                actionName: "润色",
                instructions: "改写转写文本，使其更清晰。去掉口头禅和重复语句，在合适处分段，保留原意、语言、语气和细节。只返回改写后的文本。",
                modelId: CustomActionModel.defaultId
            )
        case .system, .english:
            return CustomActionConfig(
                actionName: defaultActionName,
                instructions: defaultInstructions,
                modelId: CustomActionModel.defaultId
            )
        }
    }

    static let `default` = CustomActionConfig(
        actionName: defaultActionName,
        instructions: defaultInstructions,
        modelId: CustomActionModel.defaultId
    )

    private enum CodingKeys: String, CodingKey {
        case actionName, instructions, modelId
    }

    init(actionName: String, instructions: String, modelId: String = CustomActionModel.defaultId) {
        self.actionName = actionName
        self.instructions = instructions
        self.modelId = modelId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.actionName = try c.decode(String.self, forKey: .actionName)
        self.instructions = try c.decode(String.self, forKey: .instructions)
        // Older persisted configs have no modelId — fall back to the default.
        self.modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? CustomActionModel.defaultId
    }
}

/// The fixed set of models the custom action can use in V1. Each choice is a
/// chat-completion model verified against AI Builder Space's `/v1/chat/completions`.
enum CustomActionModel {
    struct Choice: Identifiable, Equatable {
        let id: String
        let displayName: String
    }

    /// DeepSeek V4 Flash — fast and cheap.
    static let deepseekV4Flash = Choice(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash")
    /// Grok 4.3 (non-reasoning) — `grok-4-fast` on AI Builder Space; the default.
    static let grok43NonReasoning = Choice(id: "grok-4-fast", displayName: "Grok 4.3 (non-reasoning)")

    static let choices: [Choice] = [deepseekV4Flash, grok43NonReasoning]

    static let defaultId = grok43NonReasoning.id

    static func displayName(for id: String) -> String {
        choices.first(where: { $0.id == id })?.displayName ?? id
    }
}