# 10 — Cross-Platform Architecture

**Status**: Proposed
**Author**: Chief Software Architect
**Date**: 2026-06-29
**Depends On**: 01-Product-Domain-Architecture.md, 03-Core-Architecture-V2.md
**Review Required**: Yes — this document defines the portability contract for OrinCore. Any platform-specific import introduced into OrinCore is an architectural violation detectable at compile time.

---

## 1. Cross-Platform Strategy

### 1.1 The Strategic Decision: Native-First, Core-Shared

Orin is a platform-native application with a shared domain core. It is **not** a cross-platform UI framework running on multiple platforms. The distinction matters for every technical decision that follows.

The shared component is `OrinCore`: a Swift Package containing all bounded-context domain logic — Session, Transcript, Intelligence, Knowledge, Learning, Vocabulary, Identity, Events, Observability, Plugin. OrinCore has zero platform-specific imports. The compiler enforces this at build time.

The native components are platform adapters: the audio capture pipeline, ASR backends, inference providers, persistence engines, meeting detectors, and UI layers. These are native per platform because they must be native. There is no higher-level abstraction that gives equivalent access to Core Audio on macOS, WASAPI on Windows, or AudioRecord on Android without the associated latency and capability constraints.

### 1.2 Why Not React Native, Flutter, or Electron

This question is asked at every cross-platform planning discussion. The answer is the same each time, and it derives from Orin's core product value rather than from engineering preference.

**The fundamental constraint**: Orin's primary value is real-time audio capture and processing. Audio capture has hard latency requirements that platform-native APIs are designed to satisfy and cross-platform runtimes are not.

| Framework | Audio Access | System Audio | Latency Model | Verdict |
|-----------|-------------|--------------|---------------|---------|
| Electron | Web Audio API | Not available | Browser event loop — 20–100ms jitter | Disqualified |
| Flutter | Platform channels to native | Partial, via plugin | Plugin boundary adds latency and allocation | Disqualified |
| React Native | Platform channels to native | Not available | Same bridge overhead as Flutter | Disqualified |
| Tauri | Web Audio API | Not available | Same as Electron for audio | Disqualified |
| **OrinCore + native adapters** | Direct platform API | Full access per platform | Native — zero bridge overhead | Selected |

Beyond audio: local LLM inference requires direct access to the GPU via platform ML APIs (Metal Performance Shaders on macOS/iOS, DirectML on Windows, GPU acceleration on Android). No cross-platform UI runtime exposes these APIs at the required depth. Meeting detection requires OS-level session notification hooks, accessibility APIs, and calendar integration that browser-based runtimes cannot access.

The conclusion is not a close call. Cross-platform UI frameworks solve the wrong problem. The problem Orin has is sharing business logic, not sharing UI.

### 1.3 The Portability Guarantee

`OrinCore` builds without modification on any platform where Swift 5.9+ is available. The Swift compiler enforces this guarantee: any attempt to import a platform-specific framework from within `OrinCore` is a compile error, not a convention violation. On Android, where the Swift toolchain is not available, the equivalent guarantee is provided by Kotlin Multiplatform: the same bounded context design is mirrored in Kotlin, with identical protocol definitions (interfaces) and domain logic.

This guarantee means:

1. A bug fixed in `OrinCore` on macOS is fixed on all platforms simultaneously.
2. A feature added to the Intelligence Context is available on all platforms the moment their adapter suite is complete.
3. A unit test written against `OrinCore` protocols runs on any CI machine without a microphone, GPU, or entitlement.
4. Windows and iOS platform development can proceed in parallel without domain logic forks.

---

## 2. OrinCore Package Definition

### 2.1 Package.swift

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OrinCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        // Windows: no minimum — Swift 5.9 on Windows Server 2019+
    ],
    products: [
        .library(
            name: "OrinCore",
            targets: ["OrinCore"]
        ),
    ],
    dependencies: [
        // No external dependencies. OrinCore is self-contained.
        // Any external dependency must be justified against the portability guarantee.
    ],
    targets: [
        .target(
            name: "OrinCore",
            dependencies: [],
            path: "Sources/OrinCore",
            swiftSettings: [
                // Enforce strict concurrency — all actors must be explicit.
                .unsafeFlags(["-strict-concurrency=complete"]),
                // Warn on any import that may be platform-specific.
                // This is documentation; the real enforcement is the build matrix.
            ]
        ),
        .testTarget(
            name: "OrinCoreTests",
            dependencies: ["OrinCore"],
            path: "Tests/OrinCoreTests"
        ),
    ]
)
```

### 2.2 Source Layout

```
OrinCore/
  Sources/OrinCore/
    Session/
      SessionAggregate.swift
      SessionStateMachine.swift
      SessionRepository.swift        // protocol — no implementation
      Participant.swift
      AudioChannel.swift
    Transcript/
      TranscriptAggregate.swift
      TranscriptSegment.swift        // immutable value type
      TranscriptRepository.swift     // protocol
    Intelligence/
      MeetingAnalysis.swift
      InferenceQueue.swift           // INV-005 serialization
      InferenceWorker.swift
      AnalysisOrchestrator.swift
      PromptBuilder.swift
      ChunkStrategy.swift
    Knowledge/
      KnowledgeGraph.swift
      KnowledgeNode.swift
      KnowledgeEdge.swift
      KnowledgeRepository.swift      // protocol
    Learning/
      CorrectionRecord.swift
      LearningService.swift
    Vocabulary/
      VocabularyItem.swift
      VocabularyContext.swift
      VocabularyRepository.swift     // protocol
      VocabularyContextBuilder.swift
    Identity/
      User.swift
      Organization.swift
      Contact.swift
    Events/
      DomainEvent.swift
      EventBus.swift                 // protocol
      EventStore.swift               // protocol
    Observability/
      MetricSink.swift               // protocol — implementations live in adapters
      AuditLog.swift                 // protocol
    Plugin/
      PluginManifest.swift
      PluginLifecycle.swift
      CapabilityGrant.swift
    Ports/
      AudioCaptureProvider.swift     // driven port
      SystemAudioCaptureProvider.swift
      ASRBackend.swift               // driven port
      InferenceProvider.swift        // driven port
      PersistenceStore.swift         // driven port
      CalendarProvider.swift         // driven port
      SyncProvider.swift             // driven port
      MeetingDetector.swift          // driven port
      NotificationProvider.swift     // driven port
    ConsentRecord.swift              // INV-010
    DomainInvariants.swift           // enforced assertions, not documentation
  Tests/OrinCoreTests/
    Session/
    Transcript/
    Intelligence/
    Knowledge/
    Vocabulary/
    Ports/                           // contract tests against mock adapters
```

### 2.3 Permitted and Prohibited Imports

The following rules are enforced by the build matrix (OrinCore is built on Linux CI in addition to macOS, which mechanically prevents any macOS-only import from surviving).

**Permitted in OrinCore:**

```swift
import Foundation          // basic types: Date, URL, UUID, Data, Locale
import Swift               // standard library
// Concurrency is part of the Swift standard library — no import needed
// Combine is permitted for reactive streams within the domain
import Combine
```

**Prohibited in OrinCore — will fail on Linux CI:**

```swift
import AVFoundation        // audio capture — use AudioCaptureProvider port
import AudioToolbox        // audio primitives — use AudioBuffer value type defined in Ports
import AudioUnit           // audio processing — adapter concern
import Speech              // Apple ASR — use ASRBackend port
import NaturalLanguage     // Apple NLP — use EntityExtractor port
import SwiftData           // persistence — use PersistenceStore port
import CoreData            // persistence
import ScreenCaptureKit    // macOS system audio — use SystemAudioCaptureProvider port
import EventKit            // calendar — use CalendarProvider port
import UIKit               // UI
import AppKit              // UI
import SwiftUI             // UI
import CloudKit            // sync — use SyncProvider port
import CoreML              // ML inference — use InferenceProvider port
import Metal               // GPU — use InferenceProvider port
```

The prohibition is enforced at three levels:
1. Linux CI build (anything Apple-only fails to compile)
2. Code review checklist: any `import` statement in OrinCore requires explicit justification
3. Static analysis rule (to be added in Phase 2): detect platform-specific type names in OrinCore source

### 2.4 Concurrency Model in OrinCore

All OrinCore service types are actors. Ports (protocols) that represent external I/O are `actor`-conforming to prevent callers from assuming synchronous access. Domain value types (`TranscriptSegment`, `VocabularyItem`, `KnowledgeNode`) are `Sendable` structs.

```swift
// Every driven port is actor-bound
protocol ASRBackend: Actor {
    func startSession(vocabulary: VocabularyContext) async throws
    func process(_ buffer: AudioBuffer) async
    var segmentStream: AsyncStream<TranscriptSegment> { get }
    func stopSession() async
}

// Domain services that coordinate ports are actors
actor InferenceWorker {
    private let provider: any InferenceProvider
    private var currentJob: InferenceJob?
    // Enforces INV-005: one job at a time, per Document 05
}

// Value types crossing actor boundaries are Sendable structs
struct TranscriptSegment: Sendable {
    let id: SegmentID
    let speakerID: ParticipantID?
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float
    let locale: Locale
    // Immutable. INV-003. See Document 01, §6.
}
```

---

## 3. Platform Adapter Matrix

The following table defines which protocol each platform implements and how. An entry of "NOT AVAILABLE" is a platform constraint, not a deferred feature — it cannot be added later without a change in platform policy.

| Feature | Protocol | macOS Adapter | Windows Adapter | iOS Adapter | Android Adapter |
|---------|----------|---------------|-----------------|-------------|-----------------|
| Mic capture | `AudioCaptureProvider` | `AVAudioEngineAdapter` | `WASAPIAudioAdapter` | `AVAudioSessionAdapter` | `AudioRecordAdapter` (Kotlin) |
| System audio | `SystemAudioCaptureProvider` | `SCKitAudioAdapter` | `WASAPILoopbackAdapter` | NOT AVAILABLE | `MediaProjectionAdapter` (Android 10+) |
| ASR (on-device) | `ASRBackend` | `SpeechTranscriberASRAdapter` | `WindowsSpeechASRAdapter` | `SFSpeechASRAdapter` | `AndroidSpeechASRAdapter` (Kotlin) |
| ASR (Whisper) | `ASRBackend` | `WhisperASRAdapter` | `WhisperASRAdapter` (same) | `WhisperASRAdapter` | `WhisperASRAdapter` |
| Local inference | `InferenceProvider` | `OllamaInferenceAdapter` | `OllamaInferenceAdapter` | NOT AVAILABLE | `GeminiNanoAdapter` (Kotlin) |
| AFM inference | `InferenceProvider` | `AFMInferenceAdapter` (Phase 3) | NOT AVAILABLE | `AFMInferenceAdapter` | NOT AVAILABLE |
| ONNX inference | `InferenceProvider` | NOT PLANNED | `ONNXRuntimeAdapter` | `CoreMLAdapter` | `ONNXRuntimeAdapter` (Kotlin) |
| Persistence | `PersistenceStore` | `SwiftDataPersistenceAdapter` | `GRDBPersistenceAdapter` | `SwiftDataPersistenceAdapter` | `RoomPersistenceAdapter` (Kotlin) |
| Calendar | `CalendarProvider` | `EventKitCalendarAdapter` | `WindowsCalendarAdapter` | `EventKitCalendarAdapter` | `CalendarContractAdapter` (Kotlin) |
| Meeting detection | `MeetingDetector` | `MacOSMeetingDetector` | `WindowsMeetingDetector` | `CallKitMeetingDetector` | `TelecomMeetingDetector` (Kotlin) |
| Sync | `SyncProvider` | `iCloudSyncAdapter` | `OneDriveSyncAdapter` | `iCloudSyncAdapter` | `GoogleDriveSyncAdapter` (Kotlin) |
| Notifications | `NotificationProvider` | `UNNotificationAdapter` | `WindowsToastAdapter` | `UNNotificationAdapter` | `FCMNotificationAdapter` (Kotlin) |

**Table legend:**
- "NOT AVAILABLE" — platform prohibits this feature; no adapter is possible without platform policy change
- "NOT PLANNED" — technically possible but outside current roadmap scope
- "(same)" — binary-identical Swift source compiles on both platforms
- "(Kotlin)" — implemented in Kotlin Multiplatform, not Swift; conforms to the equivalent Kotlin interface

---

## 4. macOS Implementation (Current State and Required Extractions)

### 4.1 Inventory

The following adapters exist in the current codebase in monolithic form. Each must be extracted to conform to the corresponding OrinCore port protocol. The extraction is a Phase 1/2 activity — it changes no observable behavior, only the structural boundary.

**AVAudioEngine → `AudioCaptureProvider`**

Current location: `RecordingService.swift`
Status: Exists. The service handles both session management logic (domain concern) and audio device configuration (adapter concern). These must be separated before the port protocol can be cleanly implemented.

Extraction path:
1. Extract `AVAudioEngineAdapter: AudioCaptureProvider` containing only device setup, buffer format negotiation, and `AsyncStream<AudioBuffer>` production
2. Move session management logic into `SessionAggregate` within OrinCore
3. `RecordingService` becomes a thin coordinator calling both

INV-011 enforcement: the adapter retains the existing ring-buffer design. No allocation occurs on the real-time render callback. The adapter is an `actor`; all configuration occurs in actor-isolated async methods called from outside the audio thread.

**ScreenCaptureKit → `SystemAudioCaptureProvider`**

Current location: `SystemAudioCaptureService.swift`
Status: Exists. Implementation is relatively clean. Primary extraction work is wrapping `SCStreamDelegate` callbacks into `AsyncStream<AudioBuffer>`.

Note: This adapter has no equivalent on iOS (platform prohibition). `SystemAudioCaptureProvider` must be an optional port — the system must function correctly when no `SystemAudioCaptureProvider` is registered.

**SpeechTranscriber → `ASRBackend`**

Current location: `SpeechTranscriberASRBackend.swift` (Phase 2A)
Status: Exists behind `useNewSpeechTranscriber` feature flag. The Phase 2A implementation already approximates the port interface. Extraction is largely renaming and conformance declaration.

**SFSpeechRecognizer → `ASRBackend`**

Current location: legacy path in transcription pipeline
Status: Exists. Kept as fallback for devices where SpeechTranscriber is unavailable. Both adapters implement the same `ASRBackend` protocol; the composition root selects based on OS version and feature flag state.

**Ollama → `InferenceProvider`**

Current location: `AIService.swift`
Status: Exists with hardcoded model IDs and no serialization. Document 05 defines the `InferenceWorker` serialization layer that must wrap this adapter. The adapter itself (HTTP calls to `localhost:11434`) is correct; the missing layer is the queue.

The AIService currently contains both the Ollama HTTP client (adapter concern) and prompt assembly logic (domain concern, belongs in OrinCore's `PromptBuilder`). These must be separated.

**SwiftData → `PersistenceStore`**

Current location: `TranscriptStore.swift`, `OrinModels.swift`
Status: Exists. SwiftData schema is defined in `OrinModels.swift`. The `PersistenceStore` protocol must be defined in OrinCore using pure Swift types (not SwiftData model types), and `SwiftDataPersistenceAdapter` translates between the two representations.

This translation layer is non-trivial: SwiftData's `@Model` macro generates platform-specific code. The adapter owns the SwiftData types; OrinCore owns the domain types; the adapter performs the mapping.

**EventKit → `CalendarProvider`**

Current location: `CalendarService.swift`
Status: Exists. Extraction is straightforward. `CalendarProvider` is a simple async protocol; `EventKitCalendarAdapter` wraps `EKEventStore` and translates `EKEvent` into OrinCore's `CalendarEvent` value type.

### 4.2 Phase 1 Extraction Priority

The following order minimizes risk while maximizing portability progress:

1. `InferenceProvider` + `InferenceWorker` — highest value; fixes the thundering herd defect (Document 05) while establishing the first extracted port
2. `ASRBackend` — second; enables the SFSpeech/SpeechTranscriber swap to be controlled by the composition root rather than scattered conditionals
3. `PersistenceStore` — third; enables OrinCore domain tests to run without SwiftData
4. `AudioCaptureProvider` — fourth; most complex due to INV-011 and INV-012 constraints; tackle after simpler ports establish the pattern
5. `CalendarProvider` — fifth; lowest coupling, straightforward
6. `SystemAudioCaptureProvider` — sixth; optional port, can proceed independently

---

## 5. Windows Implementation Plan

### 5.1 Technical Architecture Decision: OrinCore in Swift, UI in C# WinUI 3

Swift 5.9+ has official Windows support (Swift.org binary toolchain for Windows). OrinCore compiles on Windows without modification — this is verified by the Linux CI build, which uses the same non-Apple import constraints. Swift on Windows uses the MSVC runtime and links against standard Windows DLLs.

The Windows UI is implemented in C# with WinUI 3. This is the recommended approach for native Windows applications targeting Windows 10 22H2 and later. SwiftUI on Windows via `swift-winui` is experimental and not production-ready. C# WinUI 3 is stable, well-documented, and used in Microsoft's own first-party applications.

Interop between OrinCore (Swift) and the WinUI 3 shell (C#) uses C interop:

```swift
// OrinCore exports a C-compatible surface for Windows interop
// File: Sources/OrinCore/CInterop/OrinCoreC.swift

@_cdecl("orincore_session_start")
public func sessionStart(
    sessionID: UnsafeMutablePointer<CChar>,
    participantCount: Int32
) -> Int32 {
    // Bridges to SessionAggregate actor
    // Returns 0 on success, error code on failure
    // All async work is dispatched; this function returns immediately
}

@_cdecl("orincore_analysis_get")
public func analysisGet(
    sessionID: UnsafeMutablePointer<CChar>,
    callback: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void
) {
    // Callback-based async bridge for analysis retrieval
    // Result delivered as JSON string (C string owned by callee)
}
```

```csharp
// WinUI 3 shell calls OrinCore via P/Invoke
// File: OrinWindows/Interop/OrinCoreInterop.cs

[DllImport("OrinCore.dll")]
private static extern int orincore_session_start(
    [MarshalAs(UnmanagedType.LPStr)] string sessionId,
    int participantCount
);

[DllImport("OrinCore.dll")]
private static extern void orincore_analysis_get(
    [MarshalAs(UnmanagedType.LPStr)] string sessionId,
    AnalysisCallback callback
);

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
private delegate void AnalysisCallback(IntPtr jsonPtr, int length);
```

The C interop surface is minimal by design. OrinCore business logic stays in Swift. The C surface is a narrow bridge, not an attempt to replicate the Swift API in C.

### 5.2 WASAPI Audio Adapter

WASAPI (Windows Audio Session API) provides both microphone capture and system audio loopback. It is the native Windows equivalent of AVAudioEngine + ScreenCaptureKit combined.

Swift calls WASAPI via C interop. The `WASAPIAudioAdapter` is implemented as a Swift file that calls into a thin C++ shim:

```swift
// Sources/OrinWindowsAdapters/Audio/WASAPIAudioAdapter.swift
// Compiled only on Windows — excluded from macOS and iOS builds via package condition

actor WASAPIAudioAdapter: AudioCaptureProvider {
    private let wasapiHandle: OpaquePointer  // C++ WASAPI wrapper

    var audioStream: AsyncStream<AudioBuffer> {
        // Wraps WASAPI capture callback in AsyncStream continuation
    }

    func startCapture(configuration: AudioCaptureConfiguration) async throws {
        // Calls wasapi_start_capture(handle, sampleRate, channelCount)
        // C function defined in WASAPIShim.cpp
    }

    func stopCapture() async {
        // Calls wasapi_stop_capture(handle)
    }
}
```

```cpp
// Sources/OrinWindowsAdapters/Audio/WASAPIShim.cpp
// Thin C wrapper around IMMDevice, IAudioClient, IAudioCaptureClient

extern "C" {
    void* wasapi_create_capture_client(bool loopback);
    int wasapi_start_capture(void* handle, int sampleRate, int channels);
    void wasapi_stop_capture(void* handle);
    // Buffer delivery via registered callback — not polled
}
```

Loopback capture (system audio) is a WASAPI feature available with `AUDCLNT_STREAMFLAGS_LOOPBACK`. The same `WASAPIAudioAdapter` implementation supports both microphone and loopback by varying the device enumeration mode. This contrasts with macOS, where mic capture (AVAudioEngine) and system audio (ScreenCaptureKit) are separate APIs with separate adapters.

### 5.3 Windows ASR

```
Primary:   Windows.Media.SpeechRecognition
           - Supports: en-US, en-GB, de-DE, fr-FR, es-ES, zh-CN, ja-JP (language pack dependent)
           - Latency: <200ms for short utterances (on-device)
           - Integration: WinRT async API, wrapped in WindowsSpeechASRAdapter

Fallback:  whisper.cpp HTTP server (same as macOS WhisperASRAdapter)
           - Supports: 99 languages
           - Latency: 1–3s for 30s audio segments on integrated GPU
           - Required: for languages not in Windows language pack

Same WhisperASRAdapter binary from macOS compiles on Windows without modification.
whisper.cpp server is bundled with OrinWindows installer.
```

### 5.4 Windows Build System

```
CMakeLists.txt (root)
  ├── OrinCore.dll          (Swift Package — CMake finds swiftc via toolchain)
  ├── OrinWindowsAdapters   (Swift — conditionally compiled, Windows only)
  ├── WASAPIShim.dll        (C++ — compiled with MSVC, exported as C API)
  └── OrinWindows.exe       (C# WinUI 3 — MSBuild project, references OrinCore.dll)

Build pipeline:
  1. CMake configures Swift Package (OrinCore + WindowsAdapters)
  2. Swift Package Manager builds OrinCore.dll (produces .dll + .h for P/Invoke)
  3. MSVC compiles WASAPIShim.dll
  4. MSBuild compiles OrinWindows.exe, referencing all three DLLs
  5. WiX toolset packages installer
```

---

## 6. iOS Implementation Plan

### 6.1 Platform Constraints

iOS has one absolute constraint with no workaround: **system audio capture is not available to third-party applications**. Apple's security model does not permit an application to capture audio being played by another application. `SystemAudioCaptureProvider` is not registered in the iOS composition root. Features that depend on it (automatic meeting detection via app audio, system audio transcription) are not available on iOS.

This is not a deferred feature. It is a platform limitation. The iOS feature parity matrix reflects this honestly.

### 6.2 Microphone Capture

```swift
// Sources/OrinIOSAdapters/Audio/AVAudioSessionAdapter.swift

actor AVAudioSessionAdapter: AudioCaptureProvider {
    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()

    func startCapture(configuration: AudioCaptureConfiguration) async throws {
        try await session.setCategory(.record, mode: .measurement,
                                       options: .duckOthers)
        try await session.setActive(true)
        // Configure engine input node
        // Install tap — ring buffer, no allocation in callback (INV-011)
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: engine.inputNode.outputFormat(forBus: 0)
        ) { [weak self] buffer, time in
            // Post to AsyncStream continuation
            // Zero allocation on audio thread
        }
        try engine.start()
    }
}
```

Background audio requires the `audio` background mode in the app's `Info.plist` and entitlements. This is a requirement for any recording application and is standard practice.

### 6.3 Meeting Detection on iOS

Without system audio, meeting detection relies on explicit signals:

```swift
// Sources/OrinIOSAdapters/Meeting/CallKitMeetingDetector.swift

actor CallKitMeetingDetector: MeetingDetector {
    // Observes CXCallObserver for incoming/outgoing calls
    // Phone calls, FaceTime, third-party VoIP apps that use CallKit
    // Does NOT detect: Zoom, Teams calls (these do not use CallKit)
}

// Sources/OrinIOSAdapters/Meeting/EventKitMeetingDetector.swift

actor EventKitMeetingDetector: MeetingDetector {
    // Observes upcoming calendar events
    // Triggers session start 30s before event start time
    // Works for any calendar-scheduled meeting, regardless of conferencing app
}
```

The absence of `SCKit`-based app detection is significant: on iOS, Orin cannot detect that the user is in a Zoom call by observing Zoom's audio. It can only detect that a calendar event exists, or that a CallKit call is active. The user experience on iOS is therefore more dependent on calendar hygiene than on macOS.

### 6.4 Local Inference on iOS

```
Apple Foundation Models (iOS 18.1+, on-device):
  - Available: iOS 18.1 and later, devices with A17 Pro or M-series
  - Capability: 3B parameter model, English primarily
  - Access: via FoundationModels framework, wrapped in AFMInferenceAdapter
  - Constraint: requires user opt-in, may be unavailable during low battery

Core ML (fallback):
  - Quantized Phi-3 Mini or Mistral 7B in Core ML format
  - File size: 1.5–4 GB, downloaded separately
  - Performance: ~10 tokens/s on A16 Bionic
  - Wrapped in CoreMLInferenceAdapter: InferenceProvider

Ollama: NOT AVAILABLE on iOS
  - iOS sandbox prevents running a local server process
  - A remote Ollama instance on the same network is theoretically reachable
  - Not planned: network dependency violates local-first principle
```

### 6.5 iOS UI Adaptation

The iOS shell is a native SwiftUI application. It does not share UI code with macOS. It shares OrinCore entirely.

Key UI differences from macOS:

- No persistent sidebar. Navigation uses a tab bar (Today, Meetings, Knowledge, Settings) and a sheet-based session control surface.
- Session control is a floating button that expands to show recording state, transcript preview, and manual stop.
- Analysis completion triggers a local push notification if the app is backgrounded.
- Today widget (`WidgetKit`): shows today's scheduled meetings from the calendar and the most recent action items from the last completed session.
- Siri Shortcut: "Start Orin recording" triggers `SessionStartIntent` (AppIntents).

The iOS shell is scoped to Phase 4. The adapter suite described above is what Phase 4 builds.

---

## 7. Android Implementation Plan

### 7.1 OrinCore Equivalent: Kotlin Multiplatform

Swift does not run on Android. The portability guarantee on Android is provided by **Kotlin Multiplatform (KMP)**, not by Swift compilation. KMP shares business logic across Android, iOS, and (optionally) server-side targets.

The Android OrinCore equivalent is a Kotlin Multiplatform module that mirrors the Swift OrinCore package:

```
OrinCoreKMP/
  commonMain/
    session/
      SessionAggregate.kt
      SessionStateMachine.kt
    transcript/
      TranscriptSegment.kt          // immutable data class
      TranscriptRepository.kt       // interface (equivalent to Swift protocol)
    intelligence/
      InferenceWorker.kt            // coroutine-based, same serialization as Swift actor
      AnalysisOrchestrator.kt
    knowledge/
      KnowledgeGraph.kt
    vocabulary/
      VocabularyItem.kt
      VocabularyContextBuilder.kt
    ports/
      AudioCaptureProvider.kt       // interface
      ASRBackend.kt                 // interface
      InferenceProvider.kt          // interface
      PersistenceStore.kt           // interface
      CalendarProvider.kt           // interface
      MeetingDetector.kt            // interface
  androidMain/
    // Android-specific implementations
    AudioRecordAdapter.kt
    MediaProjectionAdapter.kt
    AndroidSpeechASRAdapter.kt
    GeminiNanoAdapter.kt
    RoomPersistenceAdapter.kt
    CalendarContractAdapter.kt
    TelecomMeetingDetector.kt
```

The KMP `commonMain` module has the same import restrictions as Swift OrinCore: no Android SDK imports. The `androidMain` module contains all platform-specific code. Kotlin coroutines provide the same actor-equivalent concurrency guarantees as Swift actors.

### 7.2 Android Audio

**Microphone** (`android.media.AudioRecord`):

```kotlin
// androidMain/AudioRecordAdapter.kt
class AudioRecordAdapter : AudioCaptureProvider {
    private val recorder = AudioRecord(
        MediaRecorder.AudioSource.VOICE_RECOGNITION,  // not MIC — reduces background noise
        sampleRate = 16000,
        channelConfig = AudioFormat.CHANNEL_IN_MONO,
        audioFormat = AudioFormat.ENCODING_PCM_16BIT,
        bufferSize = AudioRecord.getMinBufferSize(16000,
                        AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT) * 2
    )

    override val audioStream: Flow<AudioBuffer>
        get() = flow {
            recorder.startRecording()
            val buffer = ShortArray(bufferSize)
            while (isActive) {
                val read = recorder.read(buffer, 0, bufferSize)
                if (read > 0) emit(AudioBuffer(buffer.copyOf(read), sampleRate = 16000))
            }
        }.flowOn(Dispatchers.IO)
}
```

**System audio** (`android.media.projection.MediaProjection`, Android 10+):

MediaProjection requires the user to grant screen capture permission at runtime and requires a persistent foreground service with a visible notification. This is a higher friction interaction than macOS ScreenCaptureKit, but it is the only available mechanism. The permission prompt and notification are adapter concerns; OrinCore sees only the `AsyncStream<AudioBuffer>`.

### 7.3 Android Inference

```
Gemini Nano (primary):
  - Available: Pixel 8 Pro and later, Galaxy S24 series and later
  - Access: Android ML Kit on-device inference API
  - Capability: ~2B parameter model, English and major European languages
  - Cost: free, on-device, no network required
  - Wrapped in GeminiNanoAdapter: InferenceProvider

ONNX Runtime (secondary, broader hardware support):
  - Available: all Android devices with Android 9+
  - Models: Phi-3 Mini (1.8B), Mistral 7B quantized, in ONNX format
  - Performance: 3–8 tokens/s on mid-range hardware
  - Size: 800MB–2GB download
  - Wrapped in ONNXRuntimeAdapter: InferenceProvider

Remote Ollama (network fallback):
  - Connects to an Ollama instance on the same local network
  - Same OllamaInferenceAdapter HTTP client as macOS, compiled as shared code
  - Violates local-first principle when network is unavailable — used only as fallback
  - Requires explicit user configuration (hostname/port)
```

The `ModelRouter` (defined in Document 05) selects among these providers at runtime based on device capability, model availability, and network state.

---

## 8. Shared Sync Architecture

### 8.1 What Syncs

Sync is governed by two principles from Document 01: privacy-first (no data leaves the device without explicit consent) and user-owns-their-data (all data is portable and exportable).

The sync decision for each data type:

| Data Type | Syncs | Reason |
|-----------|-------|--------|
| `MeetingItem` metadata (title, date, duration, participants) | Yes | Essential for cross-device continuity |
| `MeetingAnalysis` (summary, action items, decisions) | Yes | The product's primary value artifact |
| `KnowledgeGraph` snapshots | Yes | Enables cross-device knowledge access |
| `VocabularyItem` (user-tier and org-tier) | Yes | Learning must be consistent across devices |
| `TranscriptSegment` | No | High volume, reconstructable from analysis |
| Raw audio | Never | Privacy invariant, INV-010 absolute |
| `TranscriptChunk` | No | Ephemeral analysis artifact, not persisted |
| Plugin state | No | Plugin-managed; sync is plugin's responsibility |

### 8.2 Sync Provider Per Platform

```
Apple platforms (macOS, iOS):
  Provider:   iCloud private zone (CloudKit CKDatabase, privateCloudDatabase)
  Encryption: CloudKit encrypts all data in transit and at rest using AES-256
  Conflicts:  CloudKit's built-in conflict resolution + application-level merge
  Cost:       Included in iCloud storage; user pays for storage above 5GB free tier

Windows:
  Provider:   OneDrive private folder (/Apps/Orin/)
  Encryption: AES-256 with key derived from user's Microsoft account credentials
  Conflicts:  Last-write-wins on field level; merge for collections
  API:        Microsoft Graph API (REST), wrapped in OneDriveSyncAdapter

Android (Phase 4):
  Provider:   Google Drive private folder (appDataFolder)
  Encryption: AES-256, Google manages key
  Conflicts:  Same as Windows
  API:        Google Drive REST API v3

Cross-platform sync (macOS ↔ Windows):
  Not directly supported in Phase 3.
  A user with both macOS and Windows devices maintains two separate data stores.
  Cross-platform sync requires a neutral storage layer — planned as a future Phase 5 feature
  using a self-hosted or third-party encrypted storage endpoint conforming to SyncProvider.
```

### 8.3 SyncProvider Protocol

```swift
// Sources/OrinCore/Ports/SyncProvider.swift

protocol SyncProvider: Actor {
    // Upload a meeting record after finalization
    func upload(_ meeting: MeetingRecord) async throws

    // Download all meeting records modified since a given date
    func fetchUpdates(since: Date) async throws -> [MeetingRecord]

    // Upload a knowledge graph snapshot
    func uploadKnowledgeSnapshot(_ snapshot: KnowledgeSnapshot) async throws

    // Fetch the latest knowledge snapshot from another device
    func fetchLatestKnowledgeSnapshot() async throws -> KnowledgeSnapshot?

    // Sync status observable for UI
    var syncState: AsyncStream<SyncState> { get }
}

enum SyncState: Sendable {
    case idle
    case syncing(progress: Double)
    case failed(Error)
    case upToDate(lastSyncAt: Date)
}
```

### 8.4 Conflict Resolution

Most sync conflicts are resolved by last-write-wins on individual fields. The exceptions are collection fields (action items, vocabulary, knowledge edges) where last-write-wins would silently discard entries added on another device.

Collection merge algorithm:
1. Each item in a collection has a stable UUID and a `createdAt` timestamp
2. On merge, the union of both collections is taken
3. Items present in both collections: the newer version wins
4. Items deleted on one device but present on the other: soft-delete wins (the deletion is respected)

This is the same strategy used by iCloud for Notes and Reminders. It handles the common case (user adds action items on one device, reviews on another) without requiring a distributed transaction protocol.

---

## 9. Feature Parity Matrix

The following table is the honest current and planned state. Dates are phases, not calendar commitments. "Never" means the platform prohibits the feature by design.

| Feature | macOS | Windows | iOS | Android |
|---------|-------|---------|-----|---------|
| Microphone recording | Phase 1 (now) | Phase 3 | Phase 4 | Phase 4 |
| System audio capture | Phase 1 (now) | Phase 3 | Never | Phase 4 |
| Auto-detection (calendar) | Phase 1 (now) | Phase 3 | Phase 4 | Phase 4 |
| Auto-detection (app audio) | Phase 1 (now) | Phase 3 | Never | Phase 4 |
| Auto-detection (CallKit) | N/A | N/A | Phase 4 | Phase 4 |
| Ollama inference | Phase 1 (now) | Phase 3 | Never | Network only |
| LM Studio inference | Phase 1 (now) | Phase 3 | Never | Network only |
| Apple Foundation Models | Phase 3 | Never | Phase 4 | Never |
| Gemini Nano inference | Never | Never | Never | Phase 4 |
| ONNX Runtime inference | Not planned | Phase 3 | Phase 4 (Core ML) | Phase 4 |
| On-device ASR (platform) | Phase 1 (now) | Phase 3 | Phase 4 | Phase 4 |
| Whisper ASR | Phase 2 | Phase 3 | Phase 4 | Phase 4 |
| Hindi / Hinglish ASR | Phase 2 (en-IN) | Phase 3 | Phase 4 | Phase 4 |
| Multilingual (99 languages) | Phase 2 (Whisper) | Phase 3 | Phase 4 | Phase 4 |
| Meeting analysis (summary) | Phase 1 (now) | Phase 3 | Phase 4 | Phase 4 |
| Action items extraction | Phase 1 (now) | Phase 3 | Phase 4 | Phase 4 |
| Knowledge graph | Phase 2 | Phase 3 | Phase 4 | Phase 4 |
| Vocabulary learning | Phase 2 | Phase 3 | Phase 4 | Phase 4 |
| Plugin system | Phase 2 | Phase 3 | Phase 4 (App Intents) | Phase 4 |
| iCloud sync | Phase 2 | N/A | Phase 4 | N/A |
| OneDrive sync | N/A | Phase 3 | N/A | N/A |
| Cross-platform sync | Phase 5 | Phase 5 | Phase 5 | Phase 5 |
| Today widget | N/A (not applicable) | N/A | Phase 4 | Phase 4 |
| Siri / voice assistant | Phase 4 (Shortcuts) | N/A | Phase 4 | Phase 4 |
| Background recording | Phase 1 (now) | Phase 3 | Phase 4 (entitlement) | Phase 4 (FGS) |

Entries marked "Never" are not pessimism — they are platform architecture facts. Recording system audio on iOS requires Apple to change the iOS security model. There is no engineering path around it from within Orin.

---

## 10. Migration Path

### 10.1 From Monolith to Cross-Platform: Four Phases

The migration follows the phase structure defined in Document 03. This section provides cross-platform-specific milestones within each phase.

**Phase 1 (Now — current development cycle)**

Goal: introduce protocol boundaries in the macOS monolith without behavior change.

Cross-platform deliverable: none. Phase 1 produces no Windows, iOS, or Android code. Its value is architectural — every new protocol boundary is a future platform's entry point.

Milestones:
- `InferenceProvider` protocol + `OllamaInferenceAdapter` extraction (also fixes Document 05 thundering herd)
- `ASRBackend` protocol + both ASR adapter extractions
- `PersistenceStore` protocol + `SwiftDataPersistenceAdapter` extraction
- All four protocols have mock adapters in `OrinCoreTests`
- OrinCore Swift Package compiles on Linux CI — **this is the portability proof**

**Phase 2 (8–10 weeks after Phase 1)**

Goal: OrinCore Swift Package extracted and referenced by macOS app. All remaining adapters extracted.

Cross-platform deliverable: OrinCore compiles on Linux CI as a pure Swift package. Windows and iOS have no code yet, but the OrinCore package is the complete shared domain.

Milestones:
- `AudioCaptureProvider` + `AVAudioEngineAdapter` extraction
- `SystemAudioCaptureProvider` + `SCKitAudioAdapter` extraction
- `CalendarProvider` + `EventKitCalendarAdapter` extraction
- `MeetingDetector` + `MacOSMeetingDetector` extraction
- OrinCore package tagged `v0.1.0` — API surface stable, breaking changes require minor version bump
- OrinCoreTests pass on Linux CI (no macOS-specific test dependencies)

**Phase 3 (12–16 weeks after Phase 2): Windows Proof-of-Concept**

Goal: validate that OrinCore's protocol boundaries work across a different platform. Windows is chosen before iOS because WASAPI and WinUI 3 expose different constraints than AVAudioEngine and SwiftUI, making it a stronger validation.

Windows POC scope:
- OrinCore.dll (Swift) built with Windows toolchain
- WASAPIAudioAdapter (Swift + C++ shim): microphone capture working
- WASAPILoopbackAdapter: system audio capture working
- WindowsSpeechASRAdapter: English ASR working
- OllamaInferenceAdapter: reused from macOS, compiled on Windows (zero changes)
- GRDBPersistenceAdapter: SQLite persistence working
- OrinWindows.exe (C# WinUI 3): minimal UI — start/stop recording, view transcript
- One complete session flow: detect mic → record → transcribe → analyze → display summary

Success criterion: a complete session completes on Windows using the same OrinCore domain logic as macOS. Any domain bug fixed in OrinCore fixes both platforms.

Apple Foundation Models adapter (`AFMInferenceAdapter`) is also introduced on macOS in Phase 3, requiring macOS 26 (macOS 16) and opt-in entitlement.

**Phase 4 (6–12 months after Phase 3): iOS and Android**

Goal: iOS and Android production-quality applications.

iOS milestones:
- `AVAudioSessionAdapter` for microphone
- `CallKitMeetingDetector` + `EventKitMeetingDetector`
- `AFMInferenceAdapter` (reused from Phase 3 macOS)
- `CoreMLInferenceAdapter` (fallback for older devices)
- `SwiftDataPersistenceAdapter` (shared with macOS)
- `iCloudSyncAdapter` (shared with macOS)
- App Store submission

Android milestones:
- Kotlin Multiplatform OrinCoreKMP with complete `commonMain` matching Swift OrinCore
- `AudioRecordAdapter` for microphone
- `MediaProjectionAdapter` for system audio (Android 10+ only)
- `GeminiNanoAdapter` for on-device inference
- `RoomPersistenceAdapter` for persistence
- `TelecomMeetingDetector` + `CalendarContractAdapter`
- Play Store submission

### 10.2 The Invariant That Makes This Work

The migration path described above is possible only because of one constraint that is maintained absolutely throughout every phase:

> **OrinCore has zero platform-specific imports.**

Every time this constraint is relaxed — even once, even "temporarily" — it creates a fork. A fork grows. Forks become rewrites. The entire cross-platform strategy depends on the compiler enforcing this constraint at every commit, not on engineers remembering to enforce it.

The Linux CI build is not optional infrastructure. It is the mechanism that makes the portability guarantee testable at every pull request. If Linux CI is disabled or bypassed, the guarantee is gone.

---

## Appendix A: OrinCore Port Protocol Definitions (Complete)

```swift
// Sources/OrinCore/Ports/AudioCaptureProvider.swift

public struct AudioCaptureConfiguration: Sendable {
    public let sampleRate: Double          // typically 16000 Hz for ASR
    public let channelCount: Int           // 1 (mono) for ASR, 2 (stereo) for system audio
    public let bitDepth: Int               // 16 or 32
    public let bufferDuration: TimeInterval // target latency in seconds
}

public struct AudioBuffer: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let channelCount: Int
    public let timestamp: Date
}

public protocol AudioCaptureProvider: Actor {
    var audioStream: AsyncStream<AudioBuffer> { get }
    func startCapture(configuration: AudioCaptureConfiguration) async throws
    func stopCapture() async
    var isCapturing: Bool { get }
}

public protocol SystemAudioCaptureProvider: Actor {
    // Identical interface to AudioCaptureProvider.
    // Separate protocol because it is optional — not all platforms implement it.
    var audioStream: AsyncStream<AudioBuffer> { get }
    func startCapture(configuration: AudioCaptureConfiguration) async throws
    func stopCapture() async
    var isCapturing: Bool { get }
}
```

```swift
// Sources/OrinCore/Ports/ASRBackend.swift

public protocol ASRBackend: Actor {
    func startSession(vocabulary: VocabularyContext) async throws
    func process(_ buffer: AudioBuffer) async
    var segmentStream: AsyncStream<TranscriptSegment> { get }
    func stopSession() async
    var supportedLocales: [Locale] { get }
}
```

```swift
// Sources/OrinCore/Ports/InferenceProvider.swift

public protocol InferenceProvider: Actor {
    var modelID: ModelID { get }
    var isAvailable: Bool { get async }
    func complete(prompt: String, options: InferenceOptions) async throws -> String
    func streamComplete(
        prompt: String,
        options: InferenceOptions
    ) -> AsyncThrowingStream<String, Error>
}

public struct InferenceOptions: Sendable {
    public let temperature: Float
    public let maxTokens: Int
    public let stopSequences: [String]
}
```

```swift
// Sources/OrinCore/Ports/PersistenceStore.swift

public protocol PersistenceStore: Actor {
    // Sessions
    func save(_ session: Session) async throws
    func fetchSession(id: SessionID) async throws -> Session?
    func fetchSessions(matching predicate: SessionPredicate) async throws -> [Session]
    func delete(sessionID: SessionID) async throws

    // Transcripts
    func save(_ transcript: Transcript) async throws
    func fetchTranscript(for sessionID: SessionID) async throws -> Transcript?

    // Analysis
    func save(_ analysis: MeetingAnalysis) async throws
    func fetchAnalysis(for sessionID: SessionID) async throws -> MeetingAnalysis?

    // Knowledge
    func save(_ node: KnowledgeNode) async throws
    func save(_ edge: KnowledgeEdge) async throws
    func fetchKnowledgeGraph() async throws -> KnowledgeGraph
}
```

```swift
// Sources/OrinCore/Ports/MeetingDetector.swift

public protocol MeetingDetector: Actor {
    var detectionStream: AsyncStream<MeetingDetectionEvent> { get }
    func startDetection() async throws
    func stopDetection() async
}

public enum MeetingDetectionEvent: Sendable {
    case meetingStarted(source: DetectionSource, participants: [String])
    case meetingEnded(source: DetectionSource)
    case calendarEventImminent(event: CalendarEvent)
}

public enum DetectionSource: Sendable {
    case systemAudio          // audio detected from conferencing app
    case calendarEvent        // calendar event starting
    case callKit              // iOS CallKit call
    case telecomManager       // Android TelecomManager
    case manual               // user manually started
}
```

```swift
// Sources/OrinCore/Ports/CalendarProvider.swift

public protocol CalendarProvider: Actor {
    func fetchUpcomingEvents(
        lookahead: TimeInterval
    ) async throws -> [CalendarEvent]

    func fetchCurrentEvents() async throws -> [CalendarEvent]
    var eventStream: AsyncStream<CalendarEvent> { get }
}

public struct CalendarEvent: Sendable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let participants: [String]
    public let conferenceURL: URL?
}
```

---

## Appendix B: Platform-Specific Package Targets

```swift
// Each platform's adapters are in a separate package that imports OrinCore.
// They are never imported by OrinCore.

// Package: OrinMacOSAdapters
.target(
    name: "OrinMacOSAdapters",
    dependencies: ["OrinCore"],
    path: "Sources/OrinMacOSAdapters"
    // Imports: AVFoundation, Speech, ScreenCaptureKit, EventKit, SwiftData, CloudKit
)

// Package: OrinWindowsAdapters (compiled only on Windows)
.target(
    name: "OrinWindowsAdapters",
    dependencies: ["OrinCore"],
    path: "Sources/OrinWindowsAdapters"
    // Imports: WinRT (via C interop), WASAPI (via C++ shim)
)

// Package: OrinIOSAdapters
.target(
    name: "OrinIOSAdapters",
    dependencies: ["OrinCore"],
    path: "Sources/OrinIOSAdapters"
    // Imports: AVFoundation, Speech, CallKit, EventKit, SwiftData, CloudKit,
    //          FoundationModels, CoreML
)
```

Android (`OrinCoreKMP`) is a Gradle project, not a Swift package. It references no Swift targets. The domain interface contract is maintained by design review, not by compiler boundary — the Kotlin interface definitions in `commonMain` are manually kept in sync with the Swift protocol definitions in `OrinCore/Ports/`.

A contract test suite (`OrinContractTests`) verifies behavioral equivalence between Swift and Kotlin implementations of each port, using a shared test vector format (JSON) that both test suites consume.
