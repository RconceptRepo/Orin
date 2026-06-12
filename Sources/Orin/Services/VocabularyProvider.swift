import Foundation

/// Provides domain-specific vocabulary hints to SpeechTranscriber to improve
/// recognition of proper nouns, product names, and recurring business terms.
///
/// # Usage
/// Set `SpeechTranscriber.contextualStrings` from `VocabularyProvider.allTerms`
/// before calling `SpeechAnalyzer.prepareToAnalyze(in:)`.
///
/// # Tuning (no rebuild required)
/// User-defined terms are stored in UserDefaults under `orin.customVocabulary`:
///
///     defaults write com.rconcept.orin orin.customVocabulary -array \
///         "ProjectName" "ClientName" "ProductTerm"
///
/// Locale is controlled separately:
///
///     defaults write com.rconcept.orin orin.speechLocale -string "en-IN"
///
/// Valid locale identifiers: "en-US" (default), "en-IN", "en-GB", "en-AU"
enum VocabularyProvider {

    // MARK: - Built-in terms

    /// Domain terms injected into every session.
    ///
    /// Covers the names, products, and platforms that SpeechTranscriber most
    /// frequently misrecognises based on benchmark session analysis (2026-06-12):
    ///
    /// | Spoken      | Without vocabulary | With vocabulary |
    /// |-------------|-------------------|-----------------|
    /// | Amarjit     | "emergent"        | Amarjit         |
    /// | Zoho        | "Zobo" / "Zoo"    | Zoho            |
    /// | Apollo      | "polo"            | Apollo          |
    /// | Clavrit     | "clever"          | Clavrit         |
    /// | outreaching | "outraging"       | outreaching     |
    static let builtInTerms: [String] = [
        // ── People ──────────────────────────────────────────────────────
        "Amarjit", "Amajid", "Amerjit", "Amarjeet",
        "Aditi", "Aarti", "Arti",
        "Yatish",
        "Abhishek",
        "Joydeep", "Joideep",
        "Parveen",
        "Vanshika",
        "Dipanshu",
        "Jasminder", "Jaswinder",
        "Mario", "Alvaro", "Rafael",

        // ── Company / brand ─────────────────────────────────────────────
        "Clavrit",

        // ── Government / domain acronyms ─────────────────────────────────
        "NHAI",
        "CDOT",
        "CVM",

        // ── Products and platforms ───────────────────────────────────────
        "Zoho", "Zoho CRM",
        "RedMine", "Redmine",
        "Baseliner",
        "ResourceHere", "Resourcia",
        "Apollo",
        "Upwork",
        "LinkedIn",
        "WhatsApp",
        "Dice", "Dice.com",
        "SAP",

        // ── Business / domain actions ────────────────────────────────────
        "outreaching", "outreach",
        "onboarding",
        "lead generation",
        "personalized email",
        "follow-up",
        "decision maker",
        "postmortem", "post-mortem",
    ]

    // MARK: - User-defined terms

    /// Custom terms supplied by the user via `defaults write com.rconcept.orin orin.customVocabulary`.
    ///
    /// These are merged with `builtInTerms` at session start. Changes take effect
    /// after an app restart (terms are read once when the session starts).
    static var userTerms: [String] {
        UserDefaults.standard.stringArray(forKey: "orin.customVocabulary") ?? []
    }

    // MARK: - Combined

    /// All terms combined — built-in plus any user-defined additions.
    ///
    /// Apple's on-device model biases recognition toward these strings.
    /// The list is capped at 100 terms (Apple's documented limit for contextualStrings).
    static var allTerms: [String] {
        Array((builtInTerms + userTerms).prefix(100))
    }

    // MARK: - Locale

    /// The locale identifier to use for SpeechTranscriber in every new session.
    ///
    /// Defaults to "en-US". Set to "en-IN" for South Asian–accented English:
    ///
    ///     defaults write com.rconcept.orin orin.speechLocale -string "en-IN"
    ///
    /// Restart Orin after changing. The new locale takes effect on the next recording.
    static var speechLocale: Locale {
        let identifier = UserDefaults.standard.string(forKey: "orin.speechLocale") ?? "en-US"
        return Locale(identifier: identifier)
    }
}
