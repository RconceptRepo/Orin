# 08 — Multilingual Architecture

**Document series:** Orin V1 Architecture Review  
**Status:** Design specification — forward-looking, five-year scope  
**Last updated:** 2026-06-29  
**Scope:** ASR layer, AI prompt layer, vocabulary system, language detection, cross-language support path

---

## Table of Contents

1. [Current State Assessment](#1-current-state-assessment)
2. [Fundamental Design Problems](#2-fundamental-design-problems)
3. [ASRBackend Protocol Design](#3-asrbackend-protocol-design)
4. [Language Detection Pipeline](#4-language-detection-pipeline)
5. [Per-Channel Locale Independence](#5-per-channel-locale-independence)
6. [Language-Parameterized AI Prompts](#6-language-parameterized-ai-prompts)
7. [Vocabulary Namespace Design](#7-vocabulary-namespace-design)
8. [Whisper Integration for Unsupported Locales](#8-whisper-integration-for-unsupported-locales)
9. [Path to Ten Languages](#9-path-to-ten-languages)
10. [Implementation Roadmap](#10-implementation-roadmap)
11. [Privacy and Size Constraints](#11-privacy-and-size-constraints)
12. [Summary of Design Decisions](#12-summary-of-design-decisions)

---

## 1. Current State Assessment

### 1.1 ASR Layer

Orin today is an English-only system at every architectural layer. The specific locale situation is worse than "English-only" in a simple sense: the two audio channels use different hardcoded locales with no user control at the point of session initialization.

`RecordingService` (mic channel) hardcodes `en-IN` via `VocabularyProvider.speechLocale`, which does read a UserDefaults key (`orin.speechLocale`) but is only ever set from that one location and defaults to `en-IN`. `SystemAudioCaptureService` (participant audio channel) hardcodes `en-US` independently and does not read `VocabularyProvider.speechLocale` at all. The result is that if a user sets `orin.speechLocale` to `en-GB`, the microphone picks up the change but the participant channel continues transcribing with `en-US`. The two channels are already diverged by design.

Neither channel reads the user's system locale preference. An Indian user who has set their macOS system locale to `en-IN` will get `en-IN` on the mic channel (by default) but `en-US` on the participant channel regardless. A Spanish user will get `en-IN` on both channels regardless of any system setting.

### 1.2 Vocabulary System

`VocabularyProvider.swift` contains 103 hardcoded terms in a flat `[String]` array. The `.prefix(100)` truncation at the `allTerms` computed property silently drops the last three terms added to the list (`sath mein`, `suno`, `seedha`, `confirm karo` — four Hinglish terms of which one gets through, depending on array ordering). Apple's `SpeechTranscriber.contextualStrings` has a documented ceiling of 100 items.

The 103 terms fall into three categories: people names (South Asian), company/product names, and romanized Hindi vocabulary. There is no language namespace. All 103 terms are injected into every session regardless of what language the meeting is in. A Spanish-language meeting will receive `theek hai`, `haan haan`, and `bilkul theek` as contextual hints to the Spanish-locale ASR model, which is pure noise.

User-defined terms are stored in `UserDefaults` under `orin.customVocabulary` and are read once at session start. There is no UI for adding or removing them. There is no persistence mechanism beyond UserDefaults. There is no concept of organizational vocabulary, per-meeting vocabulary, or attendee-derived vocabulary.

### 1.3 AI Prompt Layer

`buildComprehensivePrompt(title:transcript:meetingType:)` in `MeetingIntelligenceService.swift` generates a fixed English prompt with English section headers (`## SUMMARY`, `## DISCUSSION POINTS`, `## ACTION ITEMS`, `## DECISIONS`, `## FOLLOW-UPS`) and English instructions regardless of the language of the transcript. If a Hindi or Spanish transcript is fed to this prompt, the LLM will respond in English because it is explicitly instructed to fill in five English sections. The transcript language has no influence on the output language.

`detectMeetingType(title:transcript:)` performs substring matching on an English-language keyword list:
- `standup`, `stand-up`, `daily sync`, `yesterday`, `today`, `blocker`
- `sprint planning`, `velocity`, `story points`
- `interview`, `candidate`, `resume`
- `sales call`, `sales demo`, `prospect`, `proposal`, `closing`

None of these terms have equivalents in Spanish, French, Hindi, or any other language. A Spanish standup (`ayer`, `hoy`, `bloqueador`) will be classified as `general`. A French sprint planning (`vélocité`, `points d'histoire`) will be classified as `general`.

`parseComprehensiveResponse(_:transcript:)` looks for section headers using English string matching via `sectionHeader(from:)`. It also contains hardcoded English filter strings: `no explicit`, `no clear`, `no follow`, `none of the`, `not mentioned`, `no action item`, `dear `, `subject:`, `to: `, `from: `. A French LLM response saying `Aucune action` would pass these filters silently and produce empty output rather than being correctly identified as "no action items."

### 1.4 Language Detection

Language detection is completely absent. Orin does not detect the language of a transcript at any point. There is no call to `NLLanguageRecognizer` anywhere in the codebase. The `MeetingItem` model has no `detectedLanguage` field. There is no mechanism to discover that a meeting held in Spanish was transcribed with an English-locale ASR model and therefore has poor transcript quality.

### 1.5 The Hinglish Gap

The 48 romanized Hindi terms in `builtInTerms` address a real and specific problem: Orin's primary users conduct meetings in Hinglish (Hindi-English code-switching). The en-IN locale on Apple's on-device model handles some romanized Hindi phrases that appear in code-switched speech, and the vocabulary hints improve recognition of these at the margin.

However, this approach has a hard ceiling. Apple does not offer a `hi-IN` locale for `SpeechTranscriber` or `SFSpeechRecognizer`. This is not a bug in Orin; it is an Apple platform limitation as of macOS 26. When a speaker delivers a full Hindi sentence, the en-IN model will misrecognize it significantly even with vocabulary hints. The vocabulary terms improve word-level accuracy but do not salvage sentence-level comprehension.

The Hinglish terms also create noise for any future non-Hinglish use. When the vocabulary system is eventually made language-aware, these 48 terms must be partitioned into a `hi` or `en-IN-hinglish` namespace and not injected into Spanish or French sessions.

---

## 2. Fundamental Design Problems

### 2.1 Single Locale Per Session

The architecture assumes one locale per session. A `SpeechTranscriber` instance is initialized with a single locale and serves that session. Multinational calls—where the mic speaker is in India (Hinglish) and participants are in Mexico (Spanish) and Germany (German)—cannot be handled by the current design. This is not merely a feature gap; it requires architectural change at the `ASRBackend` layer (designed in Section 3).

### 2.2 Per-Channel Locale Architecturally Diverged

As noted in Section 1.1, the mic channel (`RecordingService`) and participant channel (`SystemAudioCaptureService`) already use different locale selection logic. The mic channel reads `VocabularyProvider.speechLocale`; the participant channel hardcodes `en-US`. This is an accidental divergence, not a design decision. The correct design gives each channel its own `ASRBackend` instance with its own locale, selected by a shared `ASRBackendRouter` that consults user preference and backend availability per channel.

### 2.3 AI Prompt Language Hardcoded

The five section headers in `buildComprehensivePrompt` are English string constants. The LLM's response language is determined by the instruction language, not the transcript language. Adding a `responseLanguage` parameter (Section 6) and language-neutral section markers addresses this without breaking the existing response parser.

### 2.4 Vocabulary Has No Language Namespace

All 103 vocabulary terms are injected into all sessions. This creates three categories of problems:

1. **Noise injection**: Spanish-locale ASR receives Hinglish hints it cannot use.
2. **Capacity waste**: Apple's 100-term limit is partially consumed by language-inappropriate terms.
3. **No growth path**: Adding Spanish vocabulary terms would displace English/Hindi terms rather than existing alongside them in a namespaced partition.

### 2.5 No Language Detection Pipeline

Without language detection, Orin cannot know that a transcript is low-quality because the configured locale was wrong, cannot route a meeting for re-analysis with a better-matched model, and cannot select the appropriate vocabulary pack or AI prompt language for post-session analysis.

### 2.6 English-Only Support Services

Several services assume English input:

- `VoiceCommandService`: command recognition keywords are English strings
- `detectMeetingType()`: all keyword signals are English
- `parseComprehensiveResponse()`: filter strings target English LLM output patterns
- `typeSpecificContext(for:)`: all type-specific prompt additions are English
- Hallucination word scan in `MeetingIntelligenceService`: the word list is English and runs on `@MainActor` (see PB-008 in the performance document)

---

## 3. ASRBackend Protocol Design

### 3.1 Protocol Definition

The `ASRBackend` protocol is the central abstraction that decouples session management from the specific speech recognition technology used for a given locale.

```swift
import AVFoundation
import Foundation

/// Represents a single audio channel's speech recognition capability.
///
/// Each `ASRBackend` instance handles one channel (mic or system audio) for
/// one session. The `ASRBackendRouter` selects the appropriate implementation
/// based on the requested locale and what backends are available on the device.
///
/// All backends stream `TranscriptSegment` values asynchronously. Callers
/// consume the stream with `for await segment in backend.transcribe(...)`.
/// The stream terminates naturally when the audio stream ends or when the
/// backend encounters a terminal error.
///
/// Implementations must be `Sendable`. Audio data flows from AVAudioEngine
/// tap callbacks on Core Audio real-time threads; backends must not hold
/// locks or perform allocations on the callback path (see TD-002).
public protocol ASRBackend: Sendable {

    /// Locale identifiers this backend can transcribe.
    ///
    /// Used by `ASRBackendRouter` to select among available backends.
    /// Must not change after initialization.
    var supportedLocales: [Locale] { get }

    /// Returns true if this backend requires a network connection to
    /// transcribe the given locale.
    ///
    /// `ASRBackendRouter` uses this to enforce the on-device-only constraint.
    /// When the device is offline or the user has enabled airplane mode,
    /// the router will not select a backend that returns `true` here.
    var requiresNetwork: (Locale) -> Bool { get }

    /// Returns the maximum number of contextual vocabulary strings this
    /// backend accepts. The vocabulary system respects this limit before
    /// constructing the `[String]` it passes to `transcribe`.
    ///
    /// Apple `SpeechTranscriber`: 100
    /// Apple `SFSpeechRecognizer`: 100
    /// `WhisperASRBackend`: unlimited (Whisper accepts a custom vocabulary
    ///   prompt; the backend formats the list as a prompt prefix)
    var maxVocabularyTerms: Int { get }

    /// Begin transcription of an audio stream.
    ///
    /// - Parameters:
    ///   - audioStream: Buffers from one audio channel, produced at the
    ///     Core Audio I/O cadence (~46 buffers/sec at 48 kHz/1024 frames).
    ///     The backend must not block the producer; it should drain the stream
    ///     faster than real time or use an internal ring buffer.
    ///   - locale: The locale to use for recognition. Must be contained in
    ///     `supportedLocales`.
    ///   - vocabulary: Contextual strings biasing recognition toward domain
    ///     terms. The backend may silently ignore terms beyond `maxVocabularyTerms`.
    ///
    /// - Returns: An `AsyncStream` of `TranscriptSegment` values in arrival
    ///   order. Each segment carries a `speakerLabel`, `text`, `startTime`,
    ///   `endTime`, `confidence`, and `isFinal` flag.
    ///
    /// - Throws: `ASRBackendError` if the backend cannot start (locale
    ///   unsupported, authorization denied, model not downloaded, etc.)
    func transcribe(
        audioStream: AsyncStream<AVAudioPCMBuffer>,
        locale: Locale,
        vocabulary: [String]
    ) async throws -> AsyncStream<TranscriptSegment>
}

/// Errors produced by an `ASRBackend` implementation.
public enum ASRBackendError: Error, Sendable {
    case localeUnsupported(Locale)
    case authorizationDenied
    case modelNotDownloaded(String)     // model name / size hint for UI
    case networkRequired
    case sessionFailed(underlying: Error)
}
```

### 3.2 Concrete Implementations

#### SpeechTranscriberASRBackend

Wraps the existing `SpeechTranscriber` integration. This is the current primary backend for macOS 26+ devices. It uses Apple's on-device neural ASR with no network requirement.

```swift
/// Wraps Apple's `SpeechTranscriber` API (macOS 26+, iOS 26+).
///
/// Supported locales mirror Apple's published list. As of macOS 26.0:
/// en-US, en-GB, en-AU, en-IN, es-ES, es-MX, fr-FR, fr-CA, de-DE,
/// it-IT, ja-JP, ko-KR, zh-CN, zh-TW, pt-BR, pt-PT, ru-RU, ar-SA,
/// and several others. The actual list is queried at runtime via
/// `SpeechTranscriber.supportedLocales` to remain accurate as Apple
/// extends coverage.
///
/// This backend replaces the current `SFSpeechASRBackend` as the primary
/// path. It does not require an SFSpeechRecognitionRequest and does not
/// have the 1-minute session limit that older SFSpeechRecognizer code faces.
public actor SpeechTranscriberASRBackend: ASRBackend {
    public let supportedLocales: [Locale]
    public let requiresNetwork: (Locale) -> Bool = { _ in false }
    public let maxVocabularyTerms: Int = 100

    public init() async {
        // Query Apple's runtime list at initialization time.
        // Cache it; the list does not change within an app session.
        self.supportedLocales = await SpeechTranscriber.supportedLocales
            .map { Locale(identifier: $0.identifier) }
    }

    public func transcribe(
        audioStream: AsyncStream<AVAudioPCMBuffer>,
        locale: Locale,
        vocabulary: [String]
    ) async throws -> AsyncStream<TranscriptSegment> {
        guard supportedLocales.contains(locale) else {
            throw ASRBackendError.localeUnsupported(locale)
        }
        // Implementation: initialize SpeechTranscriber with locale and
        // contextualStrings, pipe audioStream buffers through the analyzer,
        // yield TranscriptSegment for each SpeechTranscriber result.
        // (Full implementation in Sources/Orin/ASR/SpeechTranscriberASRBackend.swift)
        fatalError("Implementation pending — MT-007")
    }
}
```

#### SFSpeechASRBackend

Fallback for macOS versions before 26, or for locales that `SpeechTranscriber` does not yet cover. Uses `SFSpeechRecognizer` with the existing implementation in `RecognitionSessionManager` (MT-001).

```swift
/// Wraps Apple's `SFSpeechRecognizer` API (macOS 10.15+).
///
/// This backend exists as a fallback for:
/// - macOS versions before 26 (no SpeechTranscriber)
/// - Locales dropped between SpeechTranscriber releases
/// - A/B testing between backend implementations
///
/// The 1-minute session restart limit is handled internally via the
/// RecognitionSessionManager actor (MT-001). Callers see a continuous stream.
public actor SFSpeechASRBackend: ASRBackend {
    public let supportedLocales: [Locale]
    public let requiresNetwork: (Locale) -> Bool
    public let maxVocabularyTerms: Int = 100

    public init() {
        // SFSpeechRecognizer's supported locales. On-device locales do not
        // require network; cloud locales do.
        self.supportedLocales = SFSpeechRecognizer.supportedLocales()
            .map { $0 }
        self.requiresNetwork = { locale in
            // Apple provides on-device models for major locales.
            // Less common locales route to Apple's servers.
            let onDeviceLocales: Set<String> = [
                "en-US", "en-GB", "en-AU", "en-IN",
                "es-ES", "es-MX", "fr-FR", "de-DE",
                "ja-JP", "ko-KR", "zh-CN", "zh-TW",
                "ar-SA", "ru-RU", "pt-BR", "it-IT"
            ]
            return !onDeviceLocales.contains(locale.identifier)
        }
    }

    public func transcribe(
        audioStream: AsyncStream<AVAudioPCMBuffer>,
        locale: Locale,
        vocabulary: [String]
    ) async throws -> AsyncStream<TranscriptSegment> {
        // Delegate to the extracted RecognitionSessionManager actor (MT-001)
        fatalError("Implementation pending — MT-001 + MT-007")
    }
}
```

#### WhisperASRBackend

Handles locales that Apple does not support. The primary target is `hi-IN` (Hindi), but Whisper covers 99 languages and is the correct fallback for any locale outside Apple's list. This backend runs the `whisper.cpp` native library on-device.

```swift
/// Wraps OpenAI Whisper via whisper.cpp, running entirely on-device.
///
/// `WhisperASRBackend` is selected by `ASRBackendRouter` when:
/// 1. The requested locale is not in `SpeechTranscriberASRBackend.supportedLocales`, OR
/// 2. The user has explicitly configured Whisper as their preferred backend
///    (advanced setting, not exposed by default), OR
/// 3. The `useWhisperForHindiEnabled` feature flag is set.
///
/// Models are downloaded on demand and cached in
/// `~/Library/Application Support/com.rconcept.orin/whisper-models/`.
/// The user is shown a download prompt before the first session that
/// would require Whisper.
///
/// Supported model sizes:
/// - tiny   (39 MB):  fastest, lower accuracy, adequate for Hinglish
/// - base   (74 MB):  good balance for most languages
/// - small  (244 MB): recommended for Hindi, CJK, Arabic
/// - medium (769 MB): highest accuracy, slower on CPU-only Macs
///
/// All inference runs on-device regardless of model size.
/// Vocabulary terms are passed as a Whisper "initial prompt" prefix,
/// which biases the decoder toward the listed strings.
public actor WhisperASRBackend: ASRBackend {

    /// All 99 languages Whisper supports.
    /// The full list is defined in the Whisper model's language tokens.
    public let supportedLocales: [Locale] = WhisperLanguageMap.allLocales

    /// Whisper runs on-device exclusively.
    public let requiresNetwork: (Locale) -> Bool = { _ in false }

    /// Whisper accepts an initial prompt of up to ~224 tokens (~150 words).
    /// This is more generous than Apple's 100-term limit.
    public let maxVocabularyTerms: Int = 120

    private let modelSize: WhisperModelSize
    private let whisperService: WhisperTranscriptionService

    public init(modelSize: WhisperModelSize = .small) async throws {
        self.modelSize = modelSize
        self.whisperService = try await WhisperTranscriptionService(modelSize: modelSize)
    }

    public func transcribe(
        audioStream: AsyncStream<AVAudioPCMBuffer>,
        locale: Locale,
        vocabulary: [String]
    ) async throws -> AsyncStream<TranscriptSegment> {
        guard let whisperLanguage = WhisperLanguageMap.whisperCode(for: locale) else {
            throw ASRBackendError.localeUnsupported(locale)
        }
        let initialPrompt = vocabulary.joined(separator: ", ")
        return await whisperService.transcribe(
            audioStream: audioStream,
            language: whisperLanguage,
            initialPrompt: initialPrompt
        )
    }
}

public enum WhisperModelSize: String, Sendable {
    case tiny   = "tiny"
    case base   = "base"
    case small  = "small"
    case medium = "medium"

    public var downloadSizeBytes: Int {
        switch self {
        case .tiny:   return 39_000_000
        case .base:   return 74_000_000
        case .small:  return 244_000_000
        case .medium: return 769_000_000
        }
    }
}
```

### 3.3 ASRBackendRouter

The router encapsulates all backend selection logic. It is the only place in the codebase where the decision "which backend handles this locale?" is made.

```swift
/// Selects the optimal `ASRBackend` for a given locale and channel.
///
/// Selection priority:
/// 1. If a user preference is set for the channel, honor it if possible.
/// 2. Prefer `SpeechTranscriberASRBackend` for supported locales (lowest latency,
///    no model download, deeply integrated with Apple Audio).
/// 3. Fall back to `SFSpeechASRBackend` if SpeechTranscriber does not support
///    the locale (older macOS or locale gap).
/// 4. Fall back to `WhisperASRBackend` if neither Apple backend supports the locale,
///    and the user has accepted the one-time model download.
/// 5. Return `nil` if no backend can handle the locale (caller should alert user).
///
/// The router is initialized once at app startup and shared via the
/// dependency injection container, replacing the current `ServiceContainer`
/// `[String:Any]` approach (TD-005).
public actor ASRBackendRouter {

    private let speechTranscriber: SpeechTranscriberASRBackend
    private let sfSpeech: SFSpeechASRBackend
    private let whisper: WhisperASRBackend?   // nil if model not downloaded

    public init(
        speechTranscriber: SpeechTranscriberASRBackend,
        sfSpeech: SFSpeechASRBackend,
        whisper: WhisperASRBackend?
    ) {
        self.speechTranscriber = speechTranscriber
        self.sfSpeech = sfSpeech
        self.whisper = whisper
    }

    /// Returns the best available backend for a locale, or `nil` if none is supported.
    ///
    /// - Parameters:
    ///   - locale: The locale requested for this channel.
    ///   - channel: `mic` or `systemAudio`. Used to consult per-channel user preferences.
    ///   - requireOnDevice: If `true`, network-requiring backends are excluded.
    public func backend(
        for locale: Locale,
        channel: AudioChannel,
        requireOnDevice: Bool = true
    ) -> (any ASRBackend)? {
        // Check user override for this channel
        if let overrideBackend = userPreferredBackend(for: channel, locale: locale) {
            return overrideBackend
        }
        // Prefer SpeechTranscriber
        if speechTranscriber.supportedLocales.contains(locale) {
            return speechTranscriber
        }
        // Fall back to SFSpeechRecognizer
        if sfSpeech.supportedLocales.contains(locale) {
            let needsNetwork = sfSpeech.requiresNetwork(locale)
            if !requireOnDevice || !needsNetwork {
                return sfSpeech
            }
        }
        // Fall back to Whisper
        if let whisper, whisper.supportedLocales.contains(locale) {
            return whisper
        }
        return nil
    }

    private func userPreferredBackend(
        for channel: AudioChannel,
        locale: Locale
    ) -> (any ASRBackend)? {
        // Read from Settings (MT-004 era: SettingsView backend selection)
        // Not implemented in Phase 1; returns nil always during initial rollout.
        nil
    }
}

public enum AudioChannel: String, Sendable {
    case mic
    case systemAudio
}
```

---

## 4. Language Detection Pipeline

### 4.1 Design

Language detection runs post-recording, not in real time. Real-time language detection adds latency to the recognition loop and is unnecessary for the primary use case of a single-language meeting. Post-session detection uses the finalized transcript, which has higher accuracy than incremental segments.

```swift
/// Detects the dominant language of a meeting transcript.
///
/// Runs once after recording stops, before AI analysis begins.
/// Results are stored in `MeetingItem.detectedLanguage` and used to:
/// - Select the AI prompt response language
/// - Identify locale mismatch (configured locale ≠ detected language)
/// - Select the vocabulary pack for future re-analysis
///
/// Detection uses `NLLanguageRecognizer` on the first N words of the
/// transcript to minimize compute cost. N defaults to 500 words (~3 min
/// of speech at typical business meeting pace). Longer transcripts do
/// not improve detection accuracy meaningfully.
public struct LanguageDetector: Sendable {

    private static let wordsToSample = 500

    /// The confidence threshold below which the detection result is
    /// treated as `undetermined`. Below this threshold, Orin defaults
    /// to the configured session locale's language component.
    private static let minimumConfidence: Double = 0.70

    /// Detects the dominant language of the given transcript.
    ///
    /// - Returns: An `NLLanguage` value, or `.undetermined` if confidence
    ///   is below `minimumConfidence` or the text is too short.
    public static func detect(transcript: String) -> NLLanguage {
        let words = transcript.split(separator: " ")
            .prefix(wordsToSample)
            .joined(separator: " ")
        guard words.count >= 20 else { return .undetermined }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words)

        guard
            let dominant = recognizer.dominantLanguage,
            let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant],
            confidence >= minimumConfidence
        else {
            return .undetermined
        }
        return dominant
    }

    /// Returns hypotheses with confidence values for UI display.
    ///
    /// Used in the meeting detail view when the detected language
    /// differs from the configured locale by more than one language family.
    public static func hypotheses(
        transcript: String,
        maxCount: Int = 3
    ) -> [(language: NLLanguage, confidence: Double)] {
        let words = transcript.split(separator: " ")
            .prefix(wordsToSample)
            .joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words)
        return recognizer.languageHypotheses(withMaximum: maxCount)
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }
}
```

### 4.2 MeetingItem Model Extension

```swift
// Addition to OrinModels.swift — MeetingItem @Model

/// The language code (`NLLanguage.rawValue`) detected from the transcript
/// after recording ended. Empty string means detection was not run or
/// returned `.undetermined`.
///
/// This value is set once by `LanguageDetector` and never overwritten
/// unless the user manually triggers re-analysis.
@Attribute var detectedLanguage: String = ""

/// True if the detected language differs from the ASR locale used for
/// the session. When true, transcript quality may be degraded and the
/// user should be offered re-analysis options.
var hasLocaleMismatch: Bool {
    guard !detectedLanguage.isEmpty else { return false }
    let detected = NLLanguage(rawValue: detectedLanguage)
    let configuredLanguage = sessionLocale.language.languageCode?.identifier ?? "en"
    return detected.rawValue != configuredLanguage
}
```

### 4.3 Language Mismatch Handling

When `hasLocaleMismatch` is `true`, the meeting detail view shows a non-blocking banner:

> "This meeting was detected as Spanish but transcribed with English (India) speech recognition. Transcription accuracy may be reduced. [Re-analyze with Spanish]"

Tapping "Re-analyze" queues the meeting through `AnalysisJobQueue` (MT-002) with the detected language's locale, triggering fresh ASR if audio is still available, or AI re-analysis with the correct prompt language if only the transcript is available.

### 4.4 Per-Channel Detection

For meetings with significant audio from both channels, detection runs independently on each channel's transcript segments before they are merged. This enables the multinational call scenario:

- Mic channel transcript → detected as Hindi (Hinglish) → `MeetingItem.micDetectedLanguage = "hi"`
- Participant channel transcript → detected as Spanish → `MeetingItem.participantDetectedLanguage = "es"`

When channels disagree, the AI prompt is parameterized with the mic channel's detected language as the primary response language (the meeting organizer's language), with a note in the system prompt that the transcript contains multi-language content.

---

## 5. Per-Channel Locale Independence

### 5.1 Current vs. Target Architecture

**Current (broken):**
```
RecordingService
  └─ SpeechTranscriber(locale: VocabularyProvider.speechLocale)   // reads UserDefaults

SystemAudioCaptureService
  └─ SFSpeechRecognizer(locale: Locale(identifier: "en-US"))       // hardcoded
```

**Target:**
```
RecordingSessionCoordinator (MT-006)
  ├─ micBackend:       ASRBackendRouter.backend(for: micLocale, channel: .mic)
  └─ systemBackend:    ASRBackendRouter.backend(for: systemLocale, channel: .systemAudio)

Each channel:
  └─ asyncStream → backend.transcribe(audioStream:locale:vocabulary:)
                   → AsyncStream<TranscriptSegment>
                   → TranscriptStore merge
```

### 5.2 Channel Locale Resolution

```swift
/// Resolves the locale for each audio channel at session start.
///
/// Resolution order:
/// 1. User's explicit per-channel override (future Settings UI)
/// 2. System locale (macOS Language & Region preference)
/// 3. `orin.speechLocale` UserDefaults key (legacy, applies to both channels)
/// 4. `en-IN` hardcoded default
///
/// The mic and participant channels are resolved independently.
/// A user who sets their system locale to `hi-IN` will get Whisper on
/// the mic channel and `en-US` on the participant channel if participants
/// are typically English speakers.
public struct ChannelLocaleResolver: Sendable {

    public struct Resolution: Sendable {
        public let micLocale: Locale
        public let systemAudioLocale: Locale
    }

    public static func resolve() -> Resolution {
        let defaultLocale = legacyLocale()

        // Per-channel user overrides (Phase 3+ Settings UI)
        let micOverride = UserDefaults.standard.string(forKey: "orin.micLocale")
        let sysOverride = UserDefaults.standard.string(forKey: "orin.systemAudioLocale")

        let micLocale = micOverride.map(Locale.init(identifier:)) ?? defaultLocale
        let sysLocale = sysOverride.map(Locale.init(identifier:)) ?? Locale(identifier: "en-US")

        return Resolution(micLocale: micLocale, systemAudioLocale: sysLocale)
    }

    private static func legacyLocale() -> Locale {
        let identifier = UserDefaults.standard.string(forKey: "orin.speechLocale") ?? "en-IN"
        return Locale(identifier: identifier)
    }
}
```

### 5.3 Multinational Call Example

A meeting where the host (mic) speaks Hinglish and two participants (system audio) speak English:

```
Session start:
  micLocale:        Locale("hi-IN")   (user set orin.micLocale = "hi-IN" via Settings)
  systemAudioLocale: Locale("en-US")   (participant default)

ASRBackendRouter selection:
  micChannel:        "hi-IN" not in SpeechTranscriberASRBackend.supportedLocales
                     "hi-IN" not in SFSpeechASRBackend.supportedLocales
                     "hi-IN" in WhisperASRBackend.supportedLocales
                     → WhisperASRBackend (model: small, language: "hi")

  systemAudioChannel: "en-US" in SpeechTranscriberASRBackend.supportedLocales
                      → SpeechTranscriberASRBackend

VocabularyContext.build(for: .mic):
  → builtIn["hi"] pack + user terms + meeting attendee names
  → 120 terms (Whisper limit)

VocabularyContext.build(for: .systemAudio):
  → builtIn["en"] pack + user terms + meeting attendee names
  → 100 terms (Apple limit)
```

---

## 6. Language-Parameterized AI Prompts

### 6.1 Language-Neutral Section Markers

The central problem with the current parser is that it relies on English section header strings in two places: the prompt that generates them and the parser that reads them. The fix is to use language-neutral markers that the LLM is explicitly instructed to preserve regardless of the language it uses for the content.

```swift
/// Language-neutral section markers used in AI prompt and response parsing.
///
/// These markers are constant ASCII strings. The LLM is instructed to write
/// them exactly as shown, using them as section delimiters regardless of
/// the language of the response content. This makes `parseComprehensiveResponse`
/// locale-agnostic: the parser always looks for these fixed markers.
///
/// Design principle: markers must be unlikely to appear in natural meeting
/// text in any language. The bracket+ALL_CAPS format achieves this.
enum SectionMarker {
    static let summary          = "[SUMMARY]"
    static let discussionPoints = "[DISCUSSION_POINTS]"
    static let actionItems      = "[ACTION_ITEMS]"
    static let decisions        = "[DECISIONS]"
    static let followUps        = "[FOLLOW_UPS]"
}
```

### 6.2 Updated Prompt Builder

```swift
/// Builds the comprehensive analysis prompt with language parameterization.
///
/// - Parameters:
///   - title: The meeting title.
///   - transcript: The meeting transcript text.
///   - meetingType: The detected meeting type (from `detectMeetingType`).
///   - responseLanguage: The `NLLanguage` in which the LLM should write its
///     response. Derived from `LanguageDetector.detect(transcript:)` or from
///     the mic channel's configured locale if detection returns `.undetermined`.
///
/// The five section markers (`[SUMMARY]`, `[ACTION_ITEMS]`, etc.) are always
/// English ASCII. All content within the sections is written in `responseLanguage`.
/// This keeps `parseComprehensiveResponse` unchanged: it still searches for
/// the same ASCII marker strings regardless of content language.
func buildComprehensivePrompt(
    title: String,
    transcript: String,
    meetingType: String,
    responseLanguage: NLLanguage = .english
) -> String {
    let languageInstruction = languageInstruction(for: responseLanguage)

    return """
    You are a meeting notes assistant. \(languageInstruction)

    Use EXACTLY these section markers, spelled exactly as shown, regardless of \
    what language you use for the content:
      [SUMMARY]
      [DISCUSSION_POINTS]
      [ACTION_ITEMS]
      [DECISIONS]
      [FOLLOW_UPS]

    Fill in each section using ONLY facts explicitly stated in the transcript. \
    Do not infer. Do not write emails. Do not add commentary outside the sections.

    MEETING TITLE: \(title)
    TRANSCRIPT:
    \(transcript)

    [SUMMARY]
    Write 2-3 sentences synthesizing the main discussion topics, decisions \
    reached, and outcomes. Do NOT copy any line from the transcript verbatim. \
    If no meaningful discussion is present, write: Insufficient information.

    [DISCUSSION_POINTS]
    List each topic as a short bullet.

    [ACTION_ITEMS]
    Only create an action item when a speaker explicitly commits to a specific \
    task, follow-up, or deliverable. Write "None" if no explicit commitments \
    were made.
    For each real action item: OWNER: name | TASK: verb-first task | \
    PRIORITY: High/Medium/Low | DUE: date or TBD

    [DECISIONS]
    List each decision as a short bullet.

    [FOLLOW_UPS]
    List each follow-up as a short bullet.
    """
}

private func languageInstruction(for language: NLLanguage) -> String {
    switch language {
    case .english:
        return "Write all section content in English."
    case .spanish:
        return "Escribe todo el contenido de las secciones en español."
    case .french:
        return "Écris tout le contenu des sections en français."
    case .german:
        return "Schreibe den gesamten Abschnittsinhalt auf Deutsch."
    case .simplifiedChinese, .traditionalChinese:
        return "用中文撰写所有部分的内容。"
    case .japanese:
        return "セクションの内容はすべて日本語で記述してください。"
    case .korean:
        return "모든 섹션 내용을 한국어로 작성하세요。"
    case .arabic:
        return "اكتب جميع محتويات الأقسام باللغة العربية."
    case .hindi:
        return "सभी अनुभागों की सामग्री हिंदी में लिखें।"
    default:
        // Fall back to English for unrecognized languages.
        // Add cases as new languages reach production readiness.
        return "Write all section content in English."
    }
}
```

### 6.3 Updated Response Parser

The parser's section-header detection requires one change: replace English header matching with `SectionMarker` constant matching.

```swift
// In parseComprehensiveResponse — sectionHeader(from:) function update

private func sectionHeader(from line: String) -> (section: String, inline: String)? {
    // Match language-neutral markers defined in SectionMarker.
    // The LLM is instructed to use these regardless of content language.
    let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)

    let mapping: [(marker: String, section: String)] = [
        (SectionMarker.summary,          "summary"),
        (SectionMarker.discussionPoints, "discussionPoints"),
        (SectionMarker.actionItems,      "actions"),
        (SectionMarker.decisions,        "decisions"),
        (SectionMarker.followUps,        "followUps"),
    ]

    for (marker, section) in mapping {
        if stripped.hasPrefix(marker) {
            let inline = String(stripped.dropFirst(marker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (section, inline)
        }
    }

    // Legacy English headers — retained during transition for prompts
    // that have not yet been updated to language-neutral markers.
    // Remove this block once all production prompt versions emit [MARKER] headers.
    let legacyMapping: [(prefix: String, section: String)] = [
        ("## SUMMARY",           "summary"),
        ("## DISCUSSION POINTS", "discussionPoints"),
        ("## ACTION ITEMS",      "actions"),
        ("## DECISIONS",         "decisions"),
        ("## FOLLOW-UPS",        "followUps"),
        ("## FOLLOW_UPS",        "followUps"),
    ]
    for (prefix, section) in legacyMapping {
        if stripped.hasPrefix(prefix) {
            let inline = String(stripped.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (section, inline)
        }
    }

    return nil
}
```

### 6.4 Multilingual Meeting Type Detection

`detectMeetingType(title:transcript:)` requires keyword variants per language. The design adds a `MeetingTypeSignals` struct that partitions keywords by language.

```swift
/// Language-keyed keyword sets for meeting type detection.
///
/// Add entries for new languages as they reach Phase 3 in the roadmap.
/// Each language set should be constructed by a native speaker, not
/// translated mechanically — meeting terminology varies significantly
/// across regional business cultures.
struct MeetingTypeSignals {

    struct Signals {
        let standup:        [String]
        let sprintPlanning: [String]
        let interview:      [String]
        let salesCall:      [String]
        let discoveryCall:  [String]
    }

    static let byLanguage: [NLLanguage: Signals] = [
        .english: Signals(
            standup:        ["standup", "stand-up", "daily sync", "daily scrum",
                             "yesterday", "today", "blocker"],
            sprintPlanning: ["sprint planning", "sprint backlog", "velocity",
                             "story points"],
            interview:      ["interview", "candidate", "hiring", "resume",
                             "tell me about yourself"],
            salesCall:      ["sales call", "sales demo", "prospect", "proposal",
                             "closing", "upsell", "churn"],
            discoveryCall:  ["discovery call", "discovery session", "pain point",
                             "use case", "requirements"]
        ),
        .spanish: Signals(
            standup:        ["standup", "daily", "sincronización diaria",
                             "ayer", "hoy", "bloqueador", "impedimento"],
            sprintPlanning: ["planificación del sprint", "velocidad",
                             "puntos de historia", "backlog del sprint"],
            interview:      ["entrevista", "candidato", "contratación",
                             "currículum", "cuéntame sobre ti"],
            salesCall:      ["llamada de ventas", "demostración", "prospecto",
                             "propuesta", "cierre", "churn"],
            discoveryCall:  ["llamada de descubrimiento", "punto de dolor",
                             "caso de uso", "requisitos"]
        ),
        .french: Signals(
            standup:        ["standup", "mêlée quotidienne", "hier", "aujourd'hui",
                             "bloquant", "point quotidien"],
            sprintPlanning: ["planification du sprint", "vélocité",
                             "points d'histoire", "backlog du sprint"],
            interview:      ["entretien", "candidat", "recrutement",
                             "CV", "parlez-moi de vous"],
            salesCall:      ["appel commercial", "démonstration", "prospect",
                             "proposition", "clôture"],
            discoveryCall:  ["appel de découverte", "point de douleur",
                             "cas d'usage", "besoins"]
        ),
        .german: Signals(
            standup:        ["standup", "tägliches meeting", "gestern", "heute",
                             "blocker", "impediment", "daily scrum"],
            sprintPlanning: ["sprint-planung", "velocity", "story-punkte",
                             "sprint-backlog"],
            interview:      ["vorstellungsgespräch", "kandidat", "einstellung",
                             "lebenslauf"],
            salesCall:      ["verkaufsgespräch", "demo", "interessent",
                             "angebot", "abschluss"],
            discoveryCall:  ["entdeckungsgespräch", "schmerzpunkt",
                             "anwendungsfall", "anforderungen"]
        ),
    ]
}

/// Updated detectMeetingType that uses multi-language signals.
static func detectMeetingType(
    title: String,
    transcript: String,
    detectedLanguage: NLLanguage = .english
) -> String {
    let combined = (title + " " + transcript.prefix(2000)).lowercased()

    // Merge English signals with the detected language's signals.
    // English is always included as the base since Hinglish and
    // partially-English meetings still fire English keywords.
    var signalSets: [MeetingTypeSignals.Signals] = []
    if let englishSignals = MeetingTypeSignals.byLanguage[.english] {
        signalSets.append(englishSignals)
    }
    if detectedLanguage != .english,
       let localizedSignals = MeetingTypeSignals.byLanguage[detectedLanguage] {
        signalSets.append(localizedSignals)
    }

    for signals in signalSets {
        if signals.standup.contains(where: combined.contains) {
            return MeetingType.standup.rawValue
        }
        if signals.sprintPlanning.contains(where: combined.contains) {
            return MeetingType.sprintPlanning.rawValue
        }
        if signals.interview.contains(where: combined.contains) {
            return MeetingType.interview.rawValue
        }
        if signals.salesCall.contains(where: combined.contains) {
            return MeetingType.salesCall.rawValue
        }
        if signals.discoveryCall.contains(where: combined.contains) {
            return MeetingType.discoveryCall.rawValue
        }
    }
    return MeetingType.general.rawValue
}
```

---

## 7. Vocabulary Namespace Design

### 7.1 Current Architecture Problems

The flat `[String]` array in `VocabularyProvider.swift` has four problems:

1. **Silent truncation**: `Array((builtInTerms + userTerms).prefix(100))` silently drops user terms when builtInTerms fills the first 100 slots. With 103 built-in terms, three are always dropped before user terms are considered.
2. **No language partitioning**: All 103 terms are sent to every session regardless of locale.
3. **No persistence beyond UserDefaults**: Organization-wide vocabulary cannot be shared; attendee names cannot be auto-derived.
4. **No learning**: User corrections to transcribed text do not improve future sessions.

### 7.2 VocabularyItem SwiftData Model

```swift
import SwiftData

/// A single vocabulary entry that biases ASR recognition toward a specific
/// word or phrase.
///
/// VocabularyItems are organized into four tiers with decreasing priority.
/// When building a session's contextual strings list, higher tiers are
/// included first and lower tiers fill remaining capacity up to the backend's
/// `maxVocabularyTerms` limit.
@Model
public final class VocabularyItem {

    /// Uniquely identifies this vocabulary entry.
    @Attribute(.unique) public var id: UUID

    /// The term to inject into ASR contextual strings.
    /// For Apple backends: the exact string form expected in recognition output.
    /// For Whisper: included in the initial prompt prefix.
    public var term: String

    /// ISO 639-1 language code this term applies to, or `"*"` for all languages.
    ///
    /// `"en"` — English only (builtIn English pack)
    /// `"hi"` — Hindi only (romanized Hinglish pack)
    /// `"es"` — Spanish only
    /// `"*"`  — Language-agnostic (proper nouns, product names, people names)
    ///
    /// At session start, `VocabularyContext.build(language:)` selects:
    ///   1. All terms with `languageCode == sessionLanguage`
    ///   2. All terms with `languageCode == "*"`
    /// Terms with a different language code are excluded.
    public var languageCode: String

    /// The tier this term belongs to.
    public var tier: VocabularyTier

    /// ISO 8601 date this term was added.
    @Attribute public var addedDate: Date

    /// Number of times this term appeared in recognized transcripts.
    /// Incremented by `CorrectionStore` when it observes the term in results.
    public var usageCount: Int

    /// True if this term was promoted from a user correction by `CorrectionStore`.
    /// Promoted terms have higher confidence than manually added ones.
    public var isAutoPromoted: Bool

    public init(
        term: String,
        languageCode: String,
        tier: VocabularyTier
    ) {
        self.id = UUID()
        self.term = term
        self.languageCode = languageCode
        self.tier = tier
        self.addedDate = .now
        self.usageCount = 0
        self.isAutoPromoted = false
    }
}

/// Priority order for vocabulary term selection (highest priority first).
///
/// When the session's contextual strings list is full, lower-tier terms
/// are excluded. Session-tier terms from meeting attendees are always
/// included first because they are the most contextually relevant.
public enum VocabularyTier: Int, Codable, Sendable, Comparable {
    case session  = 0   // attendee names derived from calendar event; reset after meeting
    case user     = 1   // added by this user via SettingsView; persisted indefinitely
    case org      = 2   // shared vocabulary (future: sync via org account)
    case builtIn  = 3   // shipped with Orin; per-language pack; read-only

    public static func < (lhs: VocabularyTier, rhs: VocabularyTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

### 7.3 VocabularyContext Builder

```swift
/// Assembles the contextual strings list for a session on a given channel.
///
/// Called once per session per channel, before the ASRBackend is initialized.
/// The assembled list respects the backend's `maxVocabularyTerms` limit and
/// the session language.
public struct VocabularyContext: Sendable {

    /// Builds the vocabulary list for a session channel.
    ///
    /// - Parameters:
    ///   - language: ISO 639-1 code of the session language (e.g. "en", "hi", "es").
    ///   - maxTerms: The backend's `maxVocabularyTerms` value.
    ///   - context: SwiftData `ModelContext` to fetch `VocabularyItem` records.
    ///   - attendeeNames: Names from the calendar event, pre-converted to strings.
    ///
    /// - Returns: A `[String]` of at most `maxTerms` terms, in priority order.
    public static func build(
        language: String,
        maxTerms: Int,
        context: ModelContext,
        attendeeNames: [String] = []
    ) throws -> [String] {
        var terms: [String] = []

        // Tier 0: session-scope attendee names (always language-agnostic)
        let sessionTerms = attendeeNames.prefix(maxTerms / 4)
        terms.append(contentsOf: sessionTerms)

        // Fetch stored VocabularyItems matching this language or "*"
        let descriptor = FetchDescriptor<VocabularyItem>(
            predicate: #Predicate { item in
                item.languageCode == language || item.languageCode == "*"
            },
            sortBy: [
                SortDescriptor(\.tier),         // tier ascending (session=0 first)
                SortDescriptor(\.usageCount, order: .reverse)
            ]
        )
        let items = try context.fetch(descriptor)

        for item in items {
            guard terms.count < maxTerms else { break }
            guard !terms.contains(item.term) else { continue }
            terms.append(item.term)
        }

        return terms
    }
}
```

### 7.4 CorrectionStore — Learning from User Edits

```swift
/// Learns from user edits to transcript text.
///
/// When a user corrects a misrecognized word in the meeting transcript view,
/// `CorrectionStore` records the correction. If the same correction appears
/// three or more times across different meetings, `CorrectionStore` promotes
/// the corrected form to the user-tier vocabulary, so future sessions
/// recognize it correctly without prompting.
///
/// All learning is on-device. Corrections are stored in SwiftData alongside
/// `VocabularyItem` and are never transmitted to any server.
///
/// The promotion threshold of 3 occurrences balances noise (one accidental
/// edit) against usefulness (a term the user consistently corrects).
public actor CorrectionStore {

    private let modelContext: ModelContext
    private let promotionThreshold = 3

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Records that the user corrected `original` to `corrected` in a transcript.
    ///
    /// If `corrected` has been seen `promotionThreshold` times, promotes it
    /// to a `VocabularyItem` with `tier == .user` and `isAutoPromoted == true`.
    public func record(original: String, corrected: String, language: String) throws {
        // Fetch or create a CorrectionRecord for this (original, corrected) pair
        // (CorrectionRecord is a companion @Model not shown here for brevity)
        // If count >= promotionThreshold, call promote(term: corrected, language: language)
        // Implementation in Sources/Orin/Vocabulary/CorrectionStore.swift
    }

    private func promote(term: String, language: String) throws {
        // Check if a VocabularyItem for this term already exists
        let existing = try modelContext.fetch(
            FetchDescriptor<VocabularyItem>(
                predicate: #Predicate { $0.term == term && $0.languageCode == language }
            )
        )
        guard existing.isEmpty else { return }

        let item = VocabularyItem(
            term: term,
            languageCode: language,
            tier: .user
        )
        item.isAutoPromoted = true
        modelContext.insert(item)
        try modelContext.save()
    }
}
```

### 7.5 Built-In Pack Migration

The existing `VocabularyProvider.builtInTerms` array must be migrated to `VocabularyItem` records on first launch. The migration partitions the existing terms into language codes:

| Terms | Language code |
|---|---|
| People names (Amarjit, Aditi, Abhishek, ...) | `"*"` (language-agnostic) |
| Company/product names (Clavrit, Zoho, Apollo, ...) | `"*"` |
| Business phrases (outreaching, onboarding, ...) | `"en"` |
| Hinglish vocabulary (theek hai, haan, ...) | `"hi"` |

After migration, `VocabularyProvider.builtInTerms` and `VocabularyProvider.allTerms` are deprecated and removed. `VocabularyContext.build(language:maxTerms:context:)` is the sole entry point for building session vocabulary.

---

## 8. Whisper Integration for Unsupported Locales

### 8.1 Why Whisper

Apple's `SpeechTranscriber` and `SFSpeechRecognizer` do not support `hi-IN` as of macOS 26. This is not a configuration gap or a missing locale string; Apple has not shipped a Hindi speech model for macOS. The only on-device, privacy-preserving path to Hindi transcription is OpenAI's Whisper model, which runs on-device via `whisper.cpp`.

`whisper.cpp` is a C++ implementation that compiles natively for macOS (arm64 and x86_64), can use Core ML or Metal for GPU acceleration, and ships as a static library with an Objective-C wrapper. It is widely used in production macOS applications (Reeder, MacWhisper, others) and is stable for production use.

### 8.2 WhisperTranscriptionService

The codebase contains `WhisperTranscriptionService` as a stub. The full implementation requires:

```swift
/// Runs Whisper inference on-device using whisper.cpp.
///
/// Architecture:
/// - `WhisperTranscriptionService` is an actor to serialize access to the
///   underlying whisper.cpp context, which is not thread-safe.
/// - Audio arrives as `AVAudioPCMBuffer` chunks from the audio tap callback.
/// - Whisper operates on 30-second windows. Buffers are accumulated in a
///   ring buffer until a 30-second window is available, then submitted to
///   whisper.cpp for transcription.
/// - The 30-second windowing matches Whisper's training context length.
///   Shorter windows reduce latency but decrease accuracy for long phrases.
///
/// Language detection within Whisper:
/// - If `language == nil`, Whisper performs its own language detection on
///   the first audio window. This is useful for auto-detection but adds
///   ~0.5s latency per window.
/// - For known languages (Hindi, Spanish, etc.), pass the ISO 639-1 code
///   directly to skip Whisper's internal detection step.
public actor WhisperTranscriptionService {

    private let whisperContext: OpaquePointer  // whisper_context* from whisper.cpp
    private let modelSize: WhisperModelSize
    private var audioAccumulator: AudioRingBuffer

    private static let windowDurationSeconds: Double = 30.0
    private static let sampleRate: Double = 16_000.0  // Whisper requires 16 kHz

    public init(modelSize: WhisperModelSize) async throws {
        let modelPath = try await Self.ensureModelDownloaded(modelSize: modelSize)
        guard let ctx = whisper_init_from_file(modelPath.path) else {
            throw ASRBackendError.modelNotDownloaded("whisper-\(modelSize.rawValue)")
        }
        self.whisperContext = ctx
        self.modelSize = modelSize
        self.audioAccumulator = AudioRingBuffer(
            capacity: Int(Self.sampleRate * Self.windowDurationSeconds)
        )
    }

    deinit {
        whisper_free(whisperContext)
    }

    /// Downloads and caches the model file if not already present.
    ///
    /// Model storage: `~/Library/Application Support/com.rconcept.orin/whisper-models/`
    /// Source: huggingface.co/ggerganov/whisper.cpp (on-demand download)
    ///
    /// The download runs on a background task. The UI observes `downloadProgress`
    /// and shows a sheet before the first session requiring Whisper.
    private static func ensureModelDownloaded(
        modelSize: WhisperModelSize
    ) async throws -> URL {
        let modelDir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("com.rconcept.orin/whisper-models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true
        )
        let modelFile = modelDir.appendingPathComponent("ggml-\(modelSize.rawValue).bin")
        if FileManager.default.fileExists(atPath: modelFile.path) {
            return modelFile
        }
        // Trigger download (implementation in WhisperModelDownloader.swift)
        try await WhisperModelDownloader.download(size: modelSize, to: modelFile)
        return modelFile
    }

    /// Transcribes audio from an `AsyncStream<AVAudioPCMBuffer>`.
    ///
    /// This is the entry point called by `WhisperASRBackend.transcribe(...)`.
    /// The method converts each buffer to 16 kHz mono Float32 (Whisper's
    /// required format) before accumulating.
    public func transcribe(
        audioStream: AsyncStream<AVAudioPCMBuffer>,
        language: String?,      // ISO 639-1 code, or nil for auto-detect
        initialPrompt: String   // vocabulary terms as comma-separated string
    ) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            Task {
                for await buffer in audioStream {
                    let samples = resampleToWhisperFormat(buffer)
                    audioAccumulator.append(samples)

                    if audioAccumulator.count >= Int(Self.sampleRate * Self.windowDurationSeconds) {
                        let window = audioAccumulator.drain()
                        let segments = runWhisperInference(
                            samples: window,
                            language: language,
                            initialPrompt: initialPrompt
                        )
                        for segment in segments {
                            continuation.yield(segment)
                        }
                    }
                }
                // Flush remaining audio shorter than a full window
                if audioAccumulator.count > 0 {
                    let remaining = audioAccumulator.drain()
                    let segments = runWhisperInference(
                        samples: remaining,
                        language: language,
                        initialPrompt: initialPrompt
                    )
                    for segment in segments { continuation.yield(segment) }
                }
                continuation.finish()
            }
        }
    }

    private func runWhisperInference(
        samples: [Float],
        language: String?,
        initialPrompt: String
    ) -> [TranscriptSegment] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.language = language.map { UnsafePointer(strdup($0)) }
        params.initial_prompt = UnsafePointer(strdup(initialPrompt))
        params.translate = false
        params.no_timestamps = false
        params.single_segment = false

        guard whisper_full(whisperContext, params, samples, Int32(samples.count)) == 0 else {
            return []
        }

        let segmentCount = Int(whisper_full_n_segments(whisperContext))
        return (0..<segmentCount).map { i in
            let text = String(cString: whisper_full_get_segment_text(whisperContext, Int32(i)))
            let t0 = Double(whisper_full_get_segment_t0(whisperContext, Int32(i))) / 100.0
            let t1 = Double(whisper_full_get_segment_t1(whisperContext, Int32(i))) / 100.0
            return TranscriptSegment(
                speakerLabel: "mic",
                text: text,
                startTime: t0,
                endTime: t1,
                confidence: 0.9,  // Whisper does not expose token-level confidence in simple mode
                isFinal: true
            )
        }
    }

    private func resampleToWhisperFormat(_ buffer: AVAudioPCMBuffer) -> [Float] {
        // Convert from session sample rate (48 kHz) to 16 kHz mono Float32.
        // Implementation uses AVAudioConverter.
        // Not shown for brevity — see Sources/Orin/ASR/AudioResampler.swift
        []
    }
}
```

### 8.3 Model Download User Experience

Before the first session that requires Whisper, Orin presents a one-time sheet:

> **Hindi speech recognition requires a download**
>
> To transcribe Hindi (hi-IN), Orin uses an on-device speech model that stays private to your Mac. Nothing is sent to any server.
>
> **Whisper Small** — 244 MB
>
> This download only happens once. You can change the model size in Settings.
>
> [Download and Continue] [Use English for this meeting]

The download happens in a background task with a progress indicator. If the user cancels, the session falls back to `SFSpeechASRBackend` with `en-IN`, which is the current behavior.

### 8.4 Metal Acceleration

On Apple Silicon Macs, `whisper.cpp` can use Core ML for inference. This reduces Whisper Small inference time from ~4s per 30-second window (CPU) to ~0.8s (Core ML on M1). On Intel Macs, GPU acceleration is not available; whisper.cpp uses BLAS for vectorized CPU inference.

The `WhisperTranscriptionService` initializer checks for Core ML availability and passes the `GGML_USE_COREML` flag at compile time. The Core ML model is a separate file (`ggml-small-encoder.mlmodelc`) downloaded alongside the GGML weights.

---

## 9. Path to Ten Languages

The following table defines the target language set, the enabling technology, and the prerequisite work for each language group. Technologies are listed in order of preference (highest quality first).

### 9.1 Language Roadmap Table

| Language | Locale | ASR Backend | Status | Prerequisite |
|---|---|---|---|---|
| English (India) | en-IN | SpeechTranscriber | Now | Fix SystemAudioCaptureService locale (QW immediate) |
| English (US) | en-US | SpeechTranscriber | Now | No change needed |
| English (UK) | en-GB | SpeechTranscriber | Now | Add locale to ChannelLocaleResolver |
| English (Australia) | en-AU | SpeechTranscriber | Now | Add locale to ChannelLocaleResolver |
| Spanish (Spain) | es-ES | SpeechTranscriber | 3 months | Spanish vocabulary pack, keyword variants, prompt parameterization |
| Spanish (Mexico) | es-MX | SpeechTranscriber | 3 months | Same as es-ES; locale variant only |
| French | fr-FR | SpeechTranscriber | 3 months | French vocabulary pack, keyword variants |
| German | de-DE | SpeechTranscriber | 3 months | German vocabulary pack, keyword variants |
| Chinese (Simplified) | zh-CN | SpeechTranscriber | 6 months | Unicode-aware hallucination detection; CJK tokenization |
| Chinese (Traditional) | zh-TW | SpeechTranscriber | 6 months | Same as zh-CN |
| Japanese | ja-JP | SpeechTranscriber | 6 months | Unicode-aware hallucination detection; tokenization |
| Korean | ko-KR | SpeechTranscriber | 6 months | Unicode-aware hallucination detection; tokenization |
| Arabic | ar-SA | SpeechTranscriber | 9 months | RTL layout support; Arabic vocabulary pack |
| Hindi (true) | hi-IN | WhisperASRBackend | 12 months | Whisper integration; Devanagari AI output; model download UX |

### 9.2 Phase-by-Phase Work

**Phase 1 — Days (Locale Fixes, Zero New Languages)**

The immediate work fixes locale handling without adding any new languages:

1. `SystemAudioCaptureService`: replace hardcoded `Locale(identifier: "en-US")` with `VocabularyProvider.speechLocale` (or a new `ChannelLocaleResolver.resolve().systemAudioLocale`). This ensures both channels respect the user's configured locale.
2. `VocabularyProvider.allTerms`: change `.prefix(100)` to log a warning when user terms are being truncated, so the silent drop is visible.
3. Add `orin.systemAudioLocale` UserDefaults key alongside the existing `orin.speechLocale` key.

**Phase 2 — Weeks (ASRBackend Protocol, Language Detection, Prompt Parameterization)**

1. Introduce `ASRBackend` protocol and `ASRBackendRouter` (Section 3). Both `SpeechTranscriberASRBackend` and `SFSpeechASRBackend` implement it. No change to recognized output or user-visible behavior.
2. Run `LanguageDetector.detect(transcript:)` after every recording. Store result in `MeetingItem.detectedLanguage`.
3. Pass `detectedLanguage` into `buildComprehensivePrompt` as `responseLanguage`. Update prompt to use `[SECTION_MARKER]` format (Section 6).
4. Update `parseComprehensiveResponse` to match language-neutral markers. Keep legacy English header matching during transition.
5. Migrate `VocabularyProvider.builtInTerms` to `VocabularyItem` SwiftData records with language namespaces (Section 7.5).

**Phase 3 — Months (Spanish, French, German)**

1. Add `VocabularyItem` built-in packs for `es`, `fr`, `de`. These include business terminology, meeting-type keywords, and common proper nouns for each language region.
2. Add Spanish, French, German keyword variants to `MeetingTypeSignals` (Section 6.4).
3. Add `languageInstruction` cases for Spanish, French, German in `buildComprehensivePrompt`.
4. Add locale options to Settings > Speech Recognition: a locale picker that writes `orin.speechLocale`.
5. Show language mismatch banner in meeting detail view when `hasLocaleMismatch == true`.

**Phase 4 — Six to Twelve Months (Whisper, CJK, Arabic)**

1. Integrate `whisper.cpp` as a Swift Package (vendored C++ or via a bridging library). Add `WhisperASRBackend` and `WhisperTranscriptionService` (Section 8).
2. Add model download UX (Section 8.3).
3. Route `hi-IN` sessions to `WhisperASRBackend` via `ASRBackendRouter`.
4. Add CJK-aware hallucination detection. The current hallucination word scan runs an O(N×M) scan on a English word list. Chinese, Japanese, and Korean text is character-based, not space-delimited. A CJK-aware version uses Unicode character category inspection instead of word splitting.
5. Add RTL layout support for Arabic meeting detail view. `TranscriptSegment` gains a `layoutDirection: LayoutDirection` field derived from the detected language.
6. Add `VocabularyItem` built-in packs for Arabic, Chinese, Japanese, Korean.

### 9.3 Apple Locale Coverage Reality Check

Apple's SpeechTranscriber coverage is subject to change per OS release. The locale list in `SpeechTranscriberASRBackend.supportedLocales` is queried at runtime, not hardcoded. The roadmap above assumes Apple maintains or expands its current coverage. If Apple drops a locale between OS releases, `ASRBackendRouter` automatically falls through to `SFSpeechASRBackend` for that locale without any code change.

---

## 10. Implementation Roadmap

### 10.1 Phase 1: Quick Wins (Days)

These changes are independently deployable and carry no architectural risk.

| Item | File | Change | Effort |
|---|---|---|---|
| Fix system audio locale | `SystemAudioCaptureService.swift` | Replace `Locale(identifier: "en-US")` with `ChannelLocaleResolver.resolve().systemAudioLocale` | 1 hour |
| Add orin.systemAudioLocale key | `ChannelLocaleResolver.swift` (new) | New 30-line struct | 1 hour |
| Log vocabulary truncation | `VocabularyProvider.swift` | Add `os_log` warning when user terms are dropped | 30 min |
| Run language detection post-recording | `MeetingIntelligenceService.swift` | Call `LanguageDetector.detect(transcript:)`, store in `MeetingItem.detectedLanguage` | 2 hours |

### 10.2 Phase 2: Core Protocol Infrastructure (Weeks 1-4)

These changes introduce the ASRBackend abstraction without changing user-visible behavior.

| Item | File | Change | Effort |
|---|---|---|---|
| ASRBackend protocol | `Sources/Orin/ASR/ASRBackend.swift` (new) | Protocol definition + error type | 1 day |
| SpeechTranscriberASRBackend | `Sources/Orin/ASR/SpeechTranscriberASRBackend.swift` (new) | Actor wrapping existing SpeechTranscriber | 2 days |
| SFSpeechASRBackend | `Sources/Orin/ASR/SFSpeechASRBackend.swift` (new) | Actor wrapping RecognitionSessionManager (MT-001) | 2 days |
| ASRBackendRouter | `Sources/Orin/ASR/ASRBackendRouter.swift` (new) | Actor with locale → backend selection | 1 day |
| ChannelLocaleResolver | `Sources/Orin/ASR/ChannelLocaleResolver.swift` (new) | Struct | 1 day |
| Language-neutral prompt markers | `MeetingIntelligenceService.swift` | Add SectionMarker enum, update buildComprehensivePrompt | 2 hours |
| Language-parameterized prompts | `MeetingIntelligenceService.swift` | Add responseLanguage parameter, languageInstruction helper | 3 hours |
| Updated response parser | `MeetingIntelligenceService.swift` | Update sectionHeader to match neutral markers | 2 hours |

### 10.3 Phase 2: Vocabulary Redesign (Weeks 3-6)

These changes redesign the vocabulary system and introduce SwiftData persistence.

| Item | File | Change | Effort |
|---|---|---|---|
| VocabularyItem @Model | `Sources/Orin/Models/OrinModels.swift` | New @Model class | 1 day |
| VocabularyContext builder | `Sources/Orin/Vocabulary/VocabularyContext.swift` (new) | Static build method | 1 day |
| CorrectionStore actor | `Sources/Orin/Vocabulary/CorrectionStore.swift` (new) | Learning from user corrections | 2 days |
| Built-in pack migration | `Sources/Orin/Vocabulary/VocabularyMigration.swift` (new) | One-time migration from flat array | 1 day |
| Settings UI for vocabulary | `Sources/Orin/Views/Settings/VocabularySettingsView.swift` (new) | List + add/remove UI | 2 days |
| Deprecate VocabularyProvider | `Sources/Orin/Services/VocabularyProvider.swift` | Mark allTerms deprecated; route callers to VocabularyContext | 1 hour |

### 10.4 Phase 3: Spanish, French, German (Weeks 7-12)

| Item | File | Change | Effort |
|---|---|---|---|
| es vocabulary pack | `Sources/Orin/Vocabulary/BuiltInPacks/` | New file, ~80 terms | 1 day |
| fr vocabulary pack | Same | New file, ~80 terms | 1 day |
| de vocabulary pack | Same | New file, ~80 terms | 1 day |
| Multilingual MeetingTypeSignals | `MeetingIntelligenceService.swift` | Add es/fr/de keyword sets | 1 day |
| Language picker in Settings | `SettingsView.swift` | Locale picker writing orin.speechLocale | 1 day |
| Mismatch banner UI | `MeetingDetailView.swift` | Conditional banner + re-analysis button | 1 day |

### 10.5 Phase 4: Whisper and CJK (Months 4-12)

| Item | File | Change | Effort |
|---|---|---|---|
| whisper.cpp Swift package | `Package.swift` | Vendor or reference whisper.cpp | 3 days |
| WhisperTranscriptionService | `Sources/Orin/ASR/WhisperTranscriptionService.swift` | Full implementation | 1 week |
| WhisperASRBackend | `Sources/Orin/ASR/WhisperASRBackend.swift` | Actor wrapping service | 1 day |
| WhisperModelDownloader | `Sources/Orin/ASR/WhisperModelDownloader.swift` | Background download + progress | 2 days |
| Model download UI sheet | `Sources/Orin/Views/` | Download prompt + progress | 1 day |
| Core ML model generation | Build scripts | Generate .mlmodelc from GGML weights | 2 days |
| CJK hallucination detection | `MeetingIntelligenceService.swift` | Unicode-aware word scan | 2 days |
| RTL layout support | `TranscriptSegment`, view layer | layoutDirection field, RTL-aware Text views | 3 days |
| Arabic vocabulary pack | `Sources/Orin/Vocabulary/BuiltInPacks/` | ~80 terms | 1 day |
| CJK vocabulary packs | Same | zh, ja, ko packs | 3 days |

---

## 11. Privacy and Size Constraints

### 11.1 On-Device Requirement

All ASR in Orin must remain on-device. This is a product commitment to users, not merely a technical preference. The privacy implications of sending meeting audio to a server are severe: meeting content is confidential business information, often protected by NDAs or legal privilege. The on-device constraint applies to all languages and all backends.

The `ASRBackendRouter.backend(for:channel:requireOnDevice:)` method enforces this via the `requireOnDevice` parameter, which defaults to `true`. No backend that returns `requiresNetwork(locale) == true` will be selected in the default configuration. The `SFSpeechASRBackend` implementation marks non-major locales as requiring network; those locales are not offered to users until they have a network-capable override (not implemented in Phase 1 or 2).

### 11.2 Whisper Model Sizes

Whisper models ship in five sizes. The relevant sizes for Orin are:

| Model | Size | CER (Hindi) | Inference time / 30s window (M1 CPU) | Inference time (M1 Core ML) |
|---|---|---|---|---|
| tiny | 39 MB | ~15% | ~0.7s | ~0.2s |
| base | 74 MB | ~10% | ~1.2s | ~0.4s |
| small | 244 MB | ~6% | ~4.0s | ~0.8s |
| medium | 769 MB | ~4% | ~12.0s | ~2.5s |

The recommended default for Hindi is `small`: it fits within a reasonable one-time download, runs comfortably under real-time on all M1+ machines even without Core ML, and achieves adequate accuracy for business meetings. `tiny` and `base` are offered as alternatives for users on low-storage devices or older Intel Macs.

Real-time constraint: Whisper must finish processing a 30-second window before the next 30-second window accumulates. On M1 CPU without Core ML, `small` at 4.0s per window is well within this constraint. On Intel Macs, `small` at approximately 15s per window (without BLAS optimization) is marginal; the `tiny` model is the recommended fallback for Intel users.

### 11.3 On-Demand Model Download

Whisper models are not bundled in the application. Bundling `small` (244 MB) plus the Core ML encoder (~50 MB) would increase the Orin distributable from its current size to over 300 MB, which would block Mac App Store distribution (200 MB limit for direct download, though apps can exceed this with on-demand resources).

Models are downloaded to `~/Library/Application Support/com.rconcept.orin/whisper-models/` on first use. Users who never configure a Whisper-dependent locale never trigger a download. The download is transparent and can be repeated if the user clears application support data.

### 11.4 Vocabulary Corrections: On-Device Only

`CorrectionStore` records are stored exclusively in the local SwiftData database. They are included in iCloud backup if the user has Orin data backed up to iCloud (a separate feature not in V1 scope). They are never transmitted to Clavrit servers, to Apple, or to any third party. This constraint must be maintained across all future integrations.

### 11.5 Language Pack Size

Built-in vocabulary packs (Section 7.3) are compiled into the application binary as Swift array literals. A 200-term pack for a single language adds approximately 8 KB to the binary. Ten language packs add approximately 80 KB. This is negligible and does not warrant on-demand loading.

---

## 12. Summary of Design Decisions

| Decision | Rationale |
|---|---|
| ASRBackend protocol as central abstraction | Isolates the recognition technology from session management. Adding Whisper, or replacing Apple ASR in the future, requires only a new conforming type plus a router update. |
| Per-channel ASRBackend instances | The mic and participant channels have legitimately different language contexts in multinational calls. A single-session-locale assumption forecloses this use case permanently. |
| Language detection post-recording, not real-time | Post-recording detection uses the highest-quality transcript and avoids adding latency to the recognition loop. Real-time detection would require a second NLP inference on every segment. |
| Language-neutral `[SECTION_MARKER]` format | Decouples the prompt language from the parser. The parser does not need to know what language the LLM used for content; it only matches ASCII markers. |
| WhisperASRBackend on-demand model download | Whisper models are too large to bundle (244 MB for small). On-demand download respects storage constraints on user devices and Mac App Store limits. |
| VocabularyItem SwiftData with language namespace | The 100-term limit requires careful allocation across languages. Namespacing ensures Spanish meetings get Spanish vocabulary, not Hinglish noise. |
| CorrectionStore auto-promotion at N=3 | One correction could be accidental. Two could be coincidence. Three repeated corrections of the same word across different meetings establishes genuine intent. |
| Retain SFSpeechASRBackend as fallback | SpeechTranscriber requires macOS 26+. Orin's user base includes machines on earlier macOS versions. A fallback path maintains backward compatibility without version-gating the multilingual feature. |
| Apple hi-IN: acknowledged limitation, not workaround | There is no way to make Apple's current ASR models transcribe Hindi accurately. Acknowledging this clearly in the codebase (and in this document) prevents repeated investigation of a non-bug. Whisper is the designed solution, not a workaround. |

---

*This document is part of the Orin V1 Architecture Review series. Related documents: 03-Audio-Pipeline.md (ASR session management, TapState), 04-AI-Pipeline.md (InferenceWorker, AnalysisJobQueue), 07-SwiftData-Architecture.md (VocabularyItem persistence model).*
