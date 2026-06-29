# Multilingual Architecture Diagrams

## 1. ASRBackend Protocol Hierarchy

```mermaid
classDiagram
    class ASRBackend {
        <<protocol>>
        +var supportedLocales: [Locale]
        +func startSession(locale: Locale, vocabulary: VocabularyContext) async throws
        +func feed(buffer: AVAudioPCMBuffer, time: AVAudioTime)
        +func endSession() async throws -> TranscriptResult
        +var transcriptPublisher: AnyPublisher~TranscriptSegment, Never~
    }

    class AppleSpeechBackend {
        -recognitionTask: SFSpeechRecognitionTask?
        -recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        +supportedLocales: [Locale]
        note "en-*, es-*, fr-*, de-*, zh-*, ja-*, ko-*\nvia SFSpeechRecognizer(locale:)"
    }

    class WhisperBackend {
        -modelPath: URL
        -whisperContext: OpaquePointer?
        +supportedLocales: [Locale]
        note "All locales Whisper supports\nhi-IN, ar, and 96 others\nRuns on-device via whisper.cpp"
    }

    class AppleFoundationModelsBackend {
        -session: FoundationModelSession?
        +supportedLocales: [Locale]
        note "Proposed: Apple Intelligence\nASR layer (future API)"
    }

    class ASRRouter {
        -backends: [ASRBackend]
        -fallbackChain: [ASRBackend]
        +func select(locale: Locale) throws -> ASRBackend
        +func selectWithFallback(locale: Locale) -> [ASRBackend]
    }

    class RecognitionSessionManager {
        <<actor — proposed MT-001>>
        -activeBackend: ASRBackend?
        -vocabulary: VocabularyContext
        +func start(locale: Locale) async throws
        +func stop() async throws -> TranscriptResult
    }

    ASRBackend <|.. AppleSpeechBackend
    ASRBackend <|.. WhisperBackend
    ASRBackend <|.. AppleFoundationModelsBackend
    ASRRouter --> ASRBackend : selects
    RecognitionSessionManager --> ASRRouter : uses
    RecognitionSessionManager --> ASRBackend : owns active
```

## 2. Language Routing Decision Tree

```mermaid
flowchart TD
    START(["User starts recording\nor changes locale setting"]) --> CL["Configured locale\ne.g. en-IN, hi-IN, es-MX"]

    CL --> Q1{"Is locale supported\nby SFSpeechRecognizer?"}

    Q1 -- "Yes (en-*, es-*, fr-*,\nde-*, zh-*, ja-*, ko-*, ...)" --> Q2{"SFSpeechRecognizer\navailable on device?"}
    Q1 -- "No (hi-IN, ar, and others\nnot in Apple list)" --> WHISPER

    Q2 -- "Yes" --> APPLE["AppleSpeechBackend\n(primary)"]
    Q2 -- "No (auth revoked,\nhardware unavailable)" --> WHISPER

    APPLE --> Q3{"Recognition result\nconfidence >= 0.6?"}
    Q3 -- "Yes" --> SUCCESS["Emit TranscriptSegment\nwith locale tag"]
    Q3 -- "No (low confidence)" --> FB1{"WhisperBackend\navailable?\n(model downloaded)"}
    FB1 -- "Yes" --> WHISPER
    FB1 -- "No" --> LOWCONF["Emit segment with\nconfidence warning flag"]

    WHISPER["WhisperBackend\n(fallback / primary for hi-IN, ar)"] --> Q4{"whisper.cpp model\nloaded in memory?"}
    Q4 -- "Yes" --> SUCCESS
    Q4 -- "No" --> LOAD["Load model from\napp bundle (lazy)"] --> Q5{"Load successful?"}
    Q5 -- "Yes" --> SUCCESS
    Q5 -- "No (corrupted / OOM)" --> FALLBACK_EN["Fallback to en-US\nAppleSpeechBackend\n+ show language warning toast"]

    FALLBACK_EN --> SUCCESS

    SUCCESS --> LD["NLLanguageRecognizer\npost-recording language detection"]
    LD --> Q6{"Detected language\ndiffers from configured?"}
    Q6 -- "Yes" --> OFFER["Offer re-analysis in\ndetected language"]
    Q6 -- "No" --> DONE(["Done"])
    OFFER --> DONE
```

## 3. Path to 10 Languages — Timeline

```mermaid
gantt
    title Orin Multilingual Rollout — Language Coverage by Quarter
    dateFormat  YYYY-MM
    axisFormat  %b %Y
    todayMarker on

    section Infrastructure
    ASRBackend protocol + ASRRouter          :done,    infra1,  2026-07, 2026-08
    RecognitionSessionManager actor           :done,    infra2,  2026-07, 2026-08
    VocabularyContext layered system          :active,  infra3,  2026-08, 2026-09
    Language-parameterized AI prompts         :         infra4,  2026-08, 2026-10
    NLLanguageRecognizer post-recording       :         infra5,  2026-09, 2026-10

    section Now — English Variants (Month 0)
    en-US (primary)                          :done,    en1, 2026-07, 2026-07
    en-GB                                    :done,    en2, 2026-07, 2026-07
    en-IN (deployed commit 4f603ea)          :done,    en3, 2026-07, 2026-07
    en-AU, en-CA                             :done,    en4, 2026-07, 2026-07

    section 3 Months — Latin European (via Apple ST)
    es-* (Spanish variants)                  :         es1, 2026-10, 2026-11
    fr-* (French variants)                   :         fr1, 2026-10, 2026-11
    de-* (German variants)                   :         de1, 2026-10, 2026-11
    pt-* (Portuguese variants)               :         pt1, 2026-11, 2026-12

    section 6 Months — CJK (via Apple ST + WhisperBackend)
    zh-Hans, zh-Hant (Mandarin)              :         zh1, 2027-01, 2027-02
    ja-JP (Japanese)                         :         ja1, 2027-01, 2027-02
    ko-KR (Korean)                           :         ko1, 2027-01, 2027-02

    section 9 Months — Arabic (WhisperBackend)
    ar-* (Arabic, RTL UI work required)      :         ar1, 2027-04, 2027-05

    section 12 Months — Hindi (WhisperBackend, Apple gap)
    hi-IN (Apple no hi-IN — Whisper only)    :         hi1, 2027-07, 2027-08
    Hinglish post-processing heuristics      :         hi2, 2027-08, 2027-09
```

## 4. VocabularyContext Build Algorithm

```mermaid
flowchart TD
    START(["buildVocabularyContext(\n  locale: Locale,\n  meetingId: UUID\n)"]) --> T1

    subgraph T1["Tier 1 — Session / Attendees (highest priority)"]
        A1["Fetch CalendarEvent attendees\nfor meetingId"] --> A2["Extract displayName tokens\n(first, last, common nick)"]
        A2 --> A3["Score: 1.0 per attendee token\nMax: 50 terms"]
    end

    T1 --> T2

    subgraph T2["Tier 2 — User Custom Terms"]
        B1["Query VocabularyItem\nwhere scope == .user\nAND (locale == nil OR locale == configured)"] --> B2["Sort by frequency DESC,\nthen createdAt DESC"]
        B2 --> B3["Score: 0.8 per term\nMax: 100 terms"]
    end

    T2 --> T3

    subgraph T3["Tier 3 — Organisation Terms"]
        C1["Query VocabularyItem\nwhere scope == .org"] --> C2["Sort by frequency DESC"]
        C2 --> C3["Score: 0.7 per term\nMax: 200 terms"]
    end

    T3 --> T4

    subgraph T4["Tier 4 — Built-In (language-parameterised)"]
        D1["Load BuiltInVocabulary.json\nfor configured locale\ne.g. built-in-en-IN.json"] --> D2["Merge with built-in-en.json\n(en base always included)"]
        D2 --> D3["Score: 0.5 per term\nCurrently: 103 terms en-only\n(capped at 100 — TD: silent drop)"]
    end

    T4 --> MERGE["Merge all tiers\n(higher tier wins on conflict)\nDeduplicate, case-normalise"]

    MERGE --> CAP{"Total > 500 terms?\n(SFSpeechRecognizer limit)"}
    CAP -- "Yes" --> TRIM["Trim by score DESC,\nthen tier priority\nuntil count <= 500"]
    CAP -- "No" --> BUILD

    TRIM --> BUILD["Build SFSpeechRecognitionRequest\n.contextualStrings = terms.map(\\.text)"]
    BUILD --> DONE(["VocabularyContext ready\nfor ASRBackend.startSession()"])

    subgraph CorrectionStore["CorrectionStore (background learning)"]
        E1["User edits transcript word"] --> E2["Increment VocabularyItem.frequency\nwhere text == correctedWord"]
        E2 --> E3{"frequency >= 3?"}
        E3 -- "Yes" --> E4["Auto-promote to User tier\nif currently BuiltIn"]
        E3 -- "No" --> E5["Keep current tier, persist frequency"]
    end
```

## 5. Language Detection Pipeline

```mermaid
sequenceDiagram
    participant REC as Recording Session
    participant RSM as RecognitionSessionManager<br/>(actor)
    participant NL as NLLanguageRecognizer<br/>(on-device, Apple NLP)
    participant TS as TranscriptStore<br/>(@MainActor)
    participant MI as MeetingItem<br/>(SwiftData)
    participant UI as MeetingsView<br/>(@MainActor)
    participant USER as User

    REC->>RSM: stop() — recording ends
    RSM->>RSM: Collect full transcript text<br/>from all TranscriptSegments

    Note over RSM,NL: Post-recording language detection (off critical path)
    RSM->>NL: NLLanguageRecognizer()<br/>.processString(fullTranscript)
    NL-->>RSM: dominantLanguage: NLLanguage<br/>hypotheses: [(language, confidence)]

    RSM->>RSM: Map NLLanguage → Locale<br/>e.g. "hi" → Locale("hi-IN")

    RSM->>TS: store detectedLocale on MeetingItem
    TS->>MI: meeting.detectedLocale = detectedLocale<br/>meeting.detectedLocaleConfidence = confidence<br/>context.save()

    Note over TS,UI: UI update
    TS-->>UI: MeetingItem publishes change

    alt Detected language differs from configured locale
        UI->>USER: Show non-intrusive banner:\n"Detected Hindi — re-analyse in Hindi?"
        USER->>UI: Tap "Re-analyse"
        UI->>RSM: reAnalyze(meetingId:, locale: detectedLocale)
        RSM->>RSM: Re-run AI analysis with\nlanguage-parameterised prompts
        RSM-->>TS: Update summary / action items
        TS-->>UI: Refresh
    else Detected language matches configured
        UI->>UI: No banner — silent store only
    end

    Note over MI: MeetingItem gains two new fields:\n  detectedLocale: String?\n  detectedLocaleConfidence: Double?
```

---

### Language Support Matrix

| Language | Locale | ASR Backend | Apple ST | Whisper | AI Prompts | Target |
|---|---|---|---|---|---|---|
| English (US/GB/AU/CA) | en-* | Apple primary | Yes | Fallback | en | Now |
| English (India) | en-IN | Apple primary | Yes | Fallback | en | Now (deployed) |
| Spanish | es-* | Apple primary | Yes | Fallback | es | Month 3 |
| French | fr-* | Apple primary | Yes | Fallback | fr | Month 3 |
| German | de-* | Apple primary | Yes | Fallback | de | Month 3 |
| Portuguese | pt-* | Apple primary | Yes | Fallback | pt | Month 3 |
| Mandarin | zh-Hans/Hant | Apple primary | Yes | Fallback | zh | Month 6 |
| Japanese | ja-JP | Apple primary | Yes | Fallback | ja | Month 6 |
| Korean | ko-KR | Apple primary | Yes | Fallback | ko | Month 6 |
| Arabic | ar-* | Whisper primary | No | Primary | ar | Month 9 |
| Hindi | hi-IN | Whisper primary | **No** | Primary | hi | Month 12 |
