import Foundation

/// Configuration for the single user-defined text transformation action.
/// All fields persist in UserDefaults; the AI Builder token stays in Keychain
/// and is never stored here.
struct CustomActionConfig: Equatable, Codable {
    var actionName: String
    var instructions: String

    var trimmedActionName: String {
        actionName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedInstructions: String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A config is usable only when both the action name and instructions are
    /// non-empty after trimming. The model is fixed (not user-selectable in
    /// V1), so it is not part of this check.
    var isConfigured: Bool {
        !trimmedActionName.isEmpty && !trimmedInstructions.isEmpty
    }

    static let defaultActionName = "Polish"
    static let defaultInstructions = """
    Rewrite the transcript for clarity. Remove filler and repeated phrases, \
    add paragraph breaks where useful, and preserve the original meaning, \
    language, tone, and level of detail. Return only the revised text.
    """

    static let `default` = CustomActionConfig(
        actionName: defaultActionName,
        instructions: defaultInstructions
    )
}

/// The fixed model id used by the custom action in V1. "deepseek-v4-flash"
/// is the direct-access id for DeepSeek V4 Flash on AI Builder Space; the
/// alias "deepseek" points at the same model. Hardcoded rather than
/// user-selectable; a future version can swap the read-only caption for a
/// GET /v1/models-driven picker.
enum CustomActionModel {
    static let id = "deepseek-v4-flash"
    /// Display name shown in Settings (a proper noun — identical in both
    /// localizations; only the leading label localizes).
    static let displayName = "DeepSeek V4 Flash"
}