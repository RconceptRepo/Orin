import Foundation

/// Runtime feature flags for the ASR pipeline migration.
///
/// Both flags default to `false` (legacy behaviour) and are toggled via
/// `defaults write com.rconcept.orin <key> -bool YES`.
///
/// Phase 2A — mic channel:
///   defaults write com.rconcept.orin orin.useNewMicPipeline -bool YES
///
/// Phase 2B — participant channel benchmark:
///   defaults write com.rconcept.orin orin.useNewParticipantPipeline -bool YES
///
/// Restart Orin after writing either key.
enum FeatureFlags {

    /// Phase 2A: Replace the SFSpeechRecognizer mic pipeline with SpeechTranscriber.
    ///
    /// When `true`:
    ///   - Mic audio goes through `SpeechAnalyzer(modules: [SpeechTranscriber])`.
    ///   - The SFSpeechRecognizer instance is not created or consulted.
    ///   - Speech Recognition permission is not required (only Microphone).
    ///   - All legacy restart / watchdog / utterance-boundary code is inactive.
    ///   - `TranscriptStore.updateMic(_:)` is still called on every result.
    ///
    /// When `false` (default): existing SFSpeechRecognizer pipeline runs unchanged.
    static var useNewMicPipeline: Bool {
        UserDefaults.standard.bool(forKey: "orin.useNewMicPipeline")
    }

    /// Phase 2B: Run the SpeechTranscriber participant pipeline **in parallel** with
    /// the legacy SFSpeechRecognizer pipeline.
    ///
    /// When `true`:
    ///   - Both pipelines receive SCStream audio simultaneously.
    ///   - SpeechTranscriber output → `TranscriptStore.updateParticipant(_:)`.
    ///   - Legacy output → `SessionLogger` only (diagnostic comparison).
    ///
    /// When `false` (default):
    ///   - Both pipelines still run (for live benchmarking via SessionLogger).
    ///   - Legacy output → `TranscriptStore.updateParticipant(_:)`.
    ///   - SpeechTranscriber output → `SessionLogger` only.
    static var useNewParticipantPipeline: Bool {
        UserDefaults.standard.bool(forKey: "orin.useNewParticipantPipeline")
    }
}
