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

        // ── Hindi / Hinglish bootstrap vocabulary pack ───────────────────
        // Biases the en-IN on-device model toward common romanised Hindi
        // words that appear in mixed-language (Hinglish) business calls.
        // These are the forms most likely to surface in SpeechAnalyzer output;
        // they won't fix wholesale Hindi silence (Apple's ASR limitation) but
        // do improve recognition of code-switched words that partially appear.
        //
        // NOTE: This is a seed pack only. A user-adaptive vocabulary system
        // (corrections → local learning → contextual strings) is planned as a
        // follow-on feature for multi-language global support.
        //
        // Transitional words
        "theek hai", "haan", "nahi", "achha", "bilkul", "zaroor",
        "abhi", "kal", "bas", "matlab", "lekin", "toh", "bhi",
        "phir", "kyunki", "isliye", "samjhe", "baat", "kaam",
        // Response affirmations
        "haan haan", "theek hai na", "ekdum", "bilkul theek",
        // Time / cadence
        "ek second", "ek minute", "thoda time", "jaldi", "aaj",
        "pehle", "phir se", "hafte mein",
        // Action verbs (imperative, used as commands in meetings)
        "karo", "karna", "bhejo", "banao", "dikhao", "bolo", "dekho",
        // Degree / quantity
        "thoda", "kaafi", "bahut", "zyada", "poora", "aadha",
        // Collaborative phrases
        "sath mein", "suno", "seedha", "confirm karo",
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
    /// Defaults to "en-IN" (Indian English — best coverage for South Asian–accented
    /// and Hinglish speech). Override via UserDefaults for other English variants:
    ///
    ///     defaults write com.rconcept.orin orin.speechLocale -string "en-US"
    ///
    /// Valid identifiers: "en-IN" (default), "en-US", "en-GB", "en-AU"
    /// Restart Orin after changing. The new locale takes effect on the next recording.
    static var speechLocale: Locale {
        let identifier = UserDefaults.standard.string(forKey: "orin.speechLocale") ?? "en-IN"
        return Locale(identifier: identifier)
    }
}
