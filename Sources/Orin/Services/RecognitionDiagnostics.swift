import Foundation
import Speech

/// Shared diagnostic counter store for both recognition channels (mic + participant).
///
/// All increment methods are safe to call from any thread — the audio I/O thread
/// calls them via TapState.feed / SystemAudioTapState.feed, and the recognition
/// callback closures call them from a MainActor Task.
///
/// Usage:
///   RecognitionDiagnostics.shared.resetMicChannel(...)      // in startRecording
///   RecognitionDiagnostics.shared.resetParticipantChannel(...)  // in startCapturing
///   RecognitionDiagnostics.shared.micBufferReceived(appended:)  // in TapState.feed
///   RecognitionDiagnostics.shared.save(logPath:)            // in stopRecording
///   RecognitionDiagnostics.shared.saveCoverageReport(...)   // in stopRecording
final class RecognitionDiagnostics: @unchecked Sendable {

    static let shared = RecognitionDiagnostics()
    private init() {}

    private let lock = NSLock()

    // MARK: - Experiment mode
    //
    // "A" = current behavior: restart recognition task when 1110 fires.
    // "B" = experimental: do NOT restart on 1110; observe whether the framework
    //       continues producing callbacks on its own. Used to determine whether
    //       1110 is a fatal terminal error or an ignorable segment boundary.
    //
    // Change to "B" and rebuild to run the Mode B experiment.
    nonisolated(unsafe) static var experimentMode: String = "A"

    // MARK: - Per-generation measurement record

    struct GenerationRecord {
        var gen: Int
        var startTime: Double          // CFAbsoluteTimeGetCurrent() at task creation
        var endTime: Double?           // at error/isFinal callback
        var charsAtStart: Int          // transcriptPrefix.count when task started
        var charsAtEnd: Int            // transcript.count at task end
        var callbackCount: Int         // recognition result callbacks received this gen
        var errorCode: Int?            // nil = isFinal; 1110 = VAD boundary; other = framework
        var firstCallbackTime: Double? // time of first recognition result callback
        var firstSnippet: String       // raw segment text at first callback (no prefix)
        var lastSnippet: String        // last 50 chars of accumulated transcript at task end
        var prevLastSnippet: String    // last 50 of prev gen at the moment this gen started

        var durationSeconds: Double? { endTime.map { $0 - startTime } }
        var charsDelta: Int { max(0, charsAtEnd - charsAtStart) }
        var timeToFirstCallbackSeconds: Double? { firstCallbackTime.map { $0 - startTime } }
    }

    // MARK: - Session metadata

    private var sessionID: String = ""
    private var _micAuthStatus: String = "unknown"
    private var _micRecognizerAvailable: Bool = false
    private var _micSupportsOnDevice: Bool = false
    private var _micLocale: String = ""
    private var _micRequiresOnDevice: Bool = false
    private var _micFinalGeneration: Int = 0
    private var _participantAuthStatus: String = "unknown"
    private var _participantRecognizerAvailable: Bool = false
    private var _participantSupportsOnDevice: Bool = false
    private var _participantLocale: String = ""
    private var _participantRequiresOnDevice: Bool = false
    private var _participantFinalGeneration: Int = 0

    // MARK: - Generation tracking

    private var _sessionStartTime: Double = 0
    private var _micGenerations: [GenerationRecord] = []
    private var _participantGenerations: [GenerationRecord] = []
    private var _micStaleResults: Int = 0
    private var _participantStaleResults: Int = 0

    // MARK: - Mic counters

    private var _micAudioBuffers: Int = 0
    private var _micBuffersAppended: Int = 0
    private var _micRecognitionCallbacks: Int = 0
    private var _micErrors1110: Int = 0
    private var _micErrorsOther: [String: Int] = [:]
    private var _micTaskCreations: Int = 0
    private var _micTaskCancellations: Int = 0

    // MARK: - Participant counters

    private var _participantAudioBuffers: Int = 0
    private var _participantBuffersAppended: Int = 0
    private var _participantRecognitionCallbacks: Int = 0
    private var _participantErrors1110: Int = 0
    private var _participantErrorsOther: [String: Int] = [:]
    private var _participantTaskCreations: Int = 0
    private var _participantTaskCancellations: Int = 0

    // MARK: - Session control

    func resetMicChannel(
        sessionID: String,
        authStatus: SFSpeechRecognizerAuthorizationStatus,
        recognizerAvailable: Bool,
        supportsOnDevice: Bool,
        locale: String
    ) {
        lock.withLock {
            self.sessionID = sessionID
            _micAuthStatus = Self.authString(authStatus)
            _micRecognizerAvailable = recognizerAvailable
            _micSupportsOnDevice = supportsOnDevice
            _micLocale = locale
            _micRequiresOnDevice = false
            _micFinalGeneration = 0
            _micAudioBuffers = 0
            _micBuffersAppended = 0
            _micRecognitionCallbacks = 0
            _micErrors1110 = 0
            _micErrorsOther = [:]
            _micTaskCreations = 0
            _micTaskCancellations = 0
            _micGenerations = []
            _micStaleResults = 0
            _sessionStartTime = 0
        }
    }

    func resetParticipantChannel(
        authStatus: SFSpeechRecognizerAuthorizationStatus,
        recognizerAvailable: Bool,
        supportsOnDevice: Bool,
        locale: String
    ) {
        lock.withLock {
            _participantAuthStatus = Self.authString(authStatus)
            _participantRecognizerAvailable = recognizerAvailable
            _participantSupportsOnDevice = supportsOnDevice
            _participantLocale = locale
            _participantRequiresOnDevice = false
            _participantFinalGeneration = 0
            _participantAudioBuffers = 0
            _participantBuffersAppended = 0
            _participantRecognitionCallbacks = 0
            _participantErrors1110 = 0
            _participantErrorsOther = [:]
            _participantTaskCreations = 0
            _participantTaskCancellations = 0
            _participantGenerations = []
            _participantStaleResults = 0
        }
    }

    private static func authString(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized:    return "authorized"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    // MARK: - Mic increments

    func micBufferReceived(appended: Bool) {
        lock.withLock {
            _micAudioBuffers += 1
            if appended { _micBuffersAppended += 1 }
        }
    }

    func micTaskCreated()         { lock.withLock { _micTaskCreations += 1 } }
    func micTaskCancelled()       { lock.withLock { _micTaskCancellations += 1 } }
    func micRecognitionCallback() { lock.withLock { _micRecognitionCallbacks += 1 } }
    func micStaleResult()         { lock.withLock { _micStaleResults += 1 } }

    func micError(_ code: Int) {
        lock.withLock {
            if code == 1110 { _micErrors1110 += 1 }
            else { _micErrorsOther[String(code), default: 0] += 1 }
        }
    }

    // MARK: - Participant increments

    func participantBufferReceived(appended: Bool) {
        lock.withLock {
            _participantAudioBuffers += 1
            if appended { _participantBuffersAppended += 1 }
        }
    }

    func participantTaskCreated()         { lock.withLock { _participantTaskCreations += 1 } }
    func participantTaskCancelled()       { lock.withLock { _participantTaskCancellations += 1 } }
    func participantRecognitionCallback() { lock.withLock { _participantRecognitionCallbacks += 1 } }
    func participantStaleResult()         { lock.withLock { _participantStaleResults += 1 } }

    func participantError(_ code: Int) {
        lock.withLock {
            if code == 1110 { _participantErrors1110 += 1 }
            else { _participantErrorsOther[String(code), default: 0] += 1 }
        }
    }

    // MARK: - Generation tracking (mic)

    func micGenerationStarted(gen: Int, charsAtStart: Int) {
        let t = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            if _sessionStartTime == 0 { _sessionStartTime = t }
            let prevLast = _micGenerations.last?.lastSnippet ?? ""
            _micGenerations.append(GenerationRecord(
                gen: gen, startTime: t, endTime: nil,
                charsAtStart: charsAtStart, charsAtEnd: charsAtStart,
                callbackCount: 0, errorCode: nil,
                firstCallbackTime: nil, firstSnippet: "", lastSnippet: "",
                prevLastSnippet: prevLast
            ))
        }
    }

    func micGenerationCallback(gen: Int, chars: Int, snippet: String) {
        let t = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            guard !_micGenerations.isEmpty,
                  _micGenerations[_micGenerations.count - 1].gen == gen else { return }
            let i = _micGenerations.count - 1
            _micGenerations[i].callbackCount += 1
            if _micGenerations[i].firstCallbackTime == nil {
                _micGenerations[i].firstCallbackTime = t
                _micGenerations[i].firstSnippet = snippet
            }
            _micGenerations[i].charsAtEnd = chars
        }
    }

    func micGenerationEnded(gen: Int, errorCode: Int, chars: Int, lastSnippet: String) {
        let t = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            guard !_micGenerations.isEmpty,
                  _micGenerations[_micGenerations.count - 1].gen == gen else { return }
            let i = _micGenerations.count - 1
            _micGenerations[i].endTime = t
            _micGenerations[i].errorCode = errorCode
            _micGenerations[i].charsAtEnd = chars
            _micGenerations[i].lastSnippet = lastSnippet
        }
    }

    // MARK: - Generation tracking (participant)

    func participantGenerationStarted(gen: Int, charsAtStart: Int) {
        let t = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            if _sessionStartTime == 0 { _sessionStartTime = t }
            let prevLast = _participantGenerations.last?.lastSnippet ?? ""
            _participantGenerations.append(GenerationRecord(
                gen: gen, startTime: t, endTime: nil,
                charsAtStart: charsAtStart, charsAtEnd: charsAtStart,
                callbackCount: 0, errorCode: nil,
                firstCallbackTime: nil, firstSnippet: "", lastSnippet: "",
                prevLastSnippet: prevLast
            ))
        }
    }

    func participantGenerationCallback(gen: Int, chars: Int, snippet: String) {
        let t = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            guard !_participantGenerations.isEmpty,
                  _participantGenerations[_participantGenerations.count - 1].gen == gen else { return }
            let i = _participantGenerations.count - 1
            _participantGenerations[i].callbackCount += 1
            if _participantGenerations[i].firstCallbackTime == nil {
                _participantGenerations[i].firstCallbackTime = t
                _participantGenerations[i].firstSnippet = snippet
            }
            _participantGenerations[i].charsAtEnd = chars
        }
    }

    func participantGenerationEnded(gen: Int, errorCode: Int, chars: Int, lastSnippet: String) {
        let t = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            guard !_participantGenerations.isEmpty,
                  _participantGenerations[_participantGenerations.count - 1].gen == gen else { return }
            let i = _participantGenerations.count - 1
            _participantGenerations[i].endTime = t
            _participantGenerations[i].errorCode = errorCode
            _participantGenerations[i].charsAtEnd = chars
            _participantGenerations[i].lastSnippet = lastSnippet
        }
    }

    // MARK: - Request config setters

    func setMicRequestConfig(requiresOnDevice: Bool) {
        lock.withLock { _micRequiresOnDevice = requiresOnDevice }
    }

    func setParticipantRequestConfig(requiresOnDevice: Bool) {
        lock.withLock { _participantRequiresOnDevice = requiresOnDevice }
    }

    func setMicFinalGeneration(_ gen: Int) {
        lock.withLock { _micFinalGeneration = gen }
    }

    func setParticipantFinalGeneration(_ gen: Int) {
        lock.withLock { _participantFinalGeneration = gen }
    }

    // MARK: - Snapshot

    struct Snapshot {
        let sessionID: String
        let micAuthStatus: String
        let micRecognizerAvailable: Bool
        let micSupportsOnDevice: Bool
        let micLocale: String
        let micRequiresOnDevice: Bool
        let micFinalGeneration: Int
        let micAudioBuffers: Int
        let micBuffersAppended: Int
        let micRecognitionCallbacks: Int
        let micErrors1110: Int
        let micErrorsOther: [String: Int]
        let micTaskCreations: Int
        let micTaskCancellations: Int
        let micStaleResults: Int
        let participantAuthStatus: String
        let participantRecognizerAvailable: Bool
        let participantSupportsOnDevice: Bool
        let participantLocale: String
        let participantRequiresOnDevice: Bool
        let participantFinalGeneration: Int
        let participantAudioBuffers: Int
        let participantBuffersAppended: Int
        let participantRecognitionCallbacks: Int
        let participantErrors1110: Int
        let participantErrorsOther: [String: Int]
        let participantTaskCreations: Int
        let participantTaskCancellations: Int
        let participantStaleResults: Int
        let micGenerations: [GenerationRecord]
        let participantGenerations: [GenerationRecord]
        let sessionStartTime: Double
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                sessionID: sessionID,
                micAuthStatus: _micAuthStatus,
                micRecognizerAvailable: _micRecognizerAvailable,
                micSupportsOnDevice: _micSupportsOnDevice,
                micLocale: _micLocale,
                micRequiresOnDevice: _micRequiresOnDevice,
                micFinalGeneration: _micFinalGeneration,
                micAudioBuffers: _micAudioBuffers,
                micBuffersAppended: _micBuffersAppended,
                micRecognitionCallbacks: _micRecognitionCallbacks,
                micErrors1110: _micErrors1110,
                micErrorsOther: _micErrorsOther,
                micTaskCreations: _micTaskCreations,
                micTaskCancellations: _micTaskCancellations,
                micStaleResults: _micStaleResults,
                participantAuthStatus: _participantAuthStatus,
                participantRecognizerAvailable: _participantRecognizerAvailable,
                participantSupportsOnDevice: _participantSupportsOnDevice,
                participantLocale: _participantLocale,
                participantRequiresOnDevice: _participantRequiresOnDevice,
                participantFinalGeneration: _participantFinalGeneration,
                participantAudioBuffers: _participantAudioBuffers,
                participantBuffersAppended: _participantBuffersAppended,
                participantRecognitionCallbacks: _participantRecognitionCallbacks,
                participantErrors1110: _participantErrors1110,
                participantErrorsOther: _participantErrorsOther,
                participantTaskCreations: _participantTaskCreations,
                participantTaskCancellations: _participantTaskCancellations,
                participantStaleResults: _participantStaleResults,
                micGenerations: _micGenerations,
                participantGenerations: _participantGenerations,
                sessionStartTime: _sessionStartTime
            )
        }
    }

    // MARK: - Diagnostics JSON export

    /// Writes diagnostics-TIMESTAMP.json and returns a one-line session-log summary.
    @discardableResult
    func save(logPath: String?) -> String {
        let s = snapshot()
        let summary = """
            [Diagnostics] mic: \
            buffers=\(s.micAudioBuffers) appended=\(s.micBuffersAppended) \
            tasks=\(s.micTaskCreations) callbacks=\(s.micRecognitionCallbacks) \
            errors1110=\(s.micErrors1110) staleResults=\(s.micStaleResults) \
            cancellations=\(s.micTaskCancellations) \
            requiresOnDevice=\(s.micRequiresOnDevice) finalGen=\(s.micFinalGeneration)
            [Diagnostics] participant: \
            buffers=\(s.participantAudioBuffers) appended=\(s.participantBuffersAppended) \
            tasks=\(s.participantTaskCreations) callbacks=\(s.participantRecognitionCallbacks) \
            errors1110=\(s.participantErrors1110) staleResults=\(s.participantStaleResults) \
            cancellations=\(s.participantTaskCancellations) \
            requiresOnDevice=\(s.participantRequiresOnDevice) finalGen=\(s.participantFinalGeneration)
            """

        let dict: [String: Any] = [
            "sessionID": s.sessionID,
            "experimentMode": Self.experimentMode,
            "mic": [
                "authorizationStatus":          s.micAuthStatus,
                "recognizerAvailable":          s.micRecognizerAvailable,
                "supportsOnDeviceRecognition":  s.micSupportsOnDevice,
                "locale":                       s.micLocale,
                "requiresOnDeviceRecognition":  s.micRequiresOnDevice,
                "finalGeneration":              s.micFinalGeneration,
                "audioBuffersReceived":         s.micAudioBuffers,
                "buffersAppended":              s.micBuffersAppended,
                "recognitionCallbacks":         s.micRecognitionCallbacks,
                "staleResultsAfter1110":        s.micStaleResults,
                "errors1110":                   s.micErrors1110,
                "errorsOther":                  s.micErrorsOther,
                "taskCreations":                s.micTaskCreations,
                "taskCancellations":            s.micTaskCancellations
            ] as [String: Any],
            "participant": [
                "authorizationStatus":          s.participantAuthStatus,
                "recognizerAvailable":          s.participantRecognizerAvailable,
                "supportsOnDeviceRecognition":  s.participantSupportsOnDevice,
                "locale":                       s.participantLocale,
                "requiresOnDeviceRecognition":  s.participantRequiresOnDevice,
                "finalGeneration":              s.participantFinalGeneration,
                "audioBuffersReceived":         s.participantAudioBuffers,
                "buffersAppended":              s.participantBuffersAppended,
                "recognitionCallbacks":         s.participantRecognitionCallbacks,
                "staleResultsAfter1110":        s.participantStaleResults,
                "errors1110":                   s.participantErrors1110,
                "errorsOther":                  s.participantErrorsOther,
                "taskCreations":                s.participantTaskCreations,
                "taskCancellations":            s.participantTaskCancellations
            ] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return summary }

        let dir: URL
        if let logPath {
            dir = URL(fileURLWithPath: logPath).deletingLastPathComponent()
        } else if let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dir = appSupport.appendingPathComponent("Orin/Logs")
        } else {
            return summary
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "diagnostics-\(formatter.string(from: Date())).json"
        try? data.write(to: dir.appendingPathComponent(name))
        return summary
    }

    // MARK: - Coverage report export

    /// Writes coverage-TIMESTAMP.json alongside the session log.
    /// Produces per-generation timing, gap analysis, transcript coverage %, and
    /// segment continuity data needed for the Restart Boundary Audit.
    func saveCoverageReport(logPath: String?, elapsedSeconds: Int) {
        let s = snapshot()
        let duration = Double(max(1, elapsedSeconds))

        func continuityNote(for rec: GenerationRecord) -> String {
            if rec.gen == 0 { return "first_generation" }
            if rec.callbackCount == 0 { return "no_speech_this_gen" }
            if rec.prevLastSnippet.isEmpty { return "prev_had_no_speech" }
            let prevWords = rec.prevLastSnippet
                .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.suffix(5)
            let thisWords = rec.firstSnippet
                .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.prefix(5)
            let overlap = Set(prevWords).intersection(Set(thisWords)).count
            if overlap >= 2 { return "likely_duplicated" }
            if overlap == 1 { return "possible_overlap" }
            return "likely_continuous"
        }

        func stats(_ arr: [Double]) -> [String: Any] {
            guard !arr.isEmpty else { return ["count": 0] }
            let sorted = arr.sorted()
            let total = arr.reduce(0, +)
            return [
                "count": arr.count,
                "minSeconds": round(sorted.first! * 1000) / 1000,
                "maxSeconds": round(sorted.last! * 1000) / 1000,
                "avgSeconds": round((total / Double(arr.count)) * 1000) / 1000,
                "p50Seconds": round(sorted[sorted.count / 2] * 1000) / 1000,
                "totalSeconds": round(total * 1000) / 1000
            ] as [String: Any]
        }

        func channelReport(gens: [GenerationRecord]) -> [String: Any] {
            let completed = gens.filter { $0.endTime != nil }
            let activeSeconds = completed.compactMap { $0.durationSeconds }.reduce(0, +)

            // Restart gaps: time from gen[N] end to gen[N+1] start
            var gaps: [Double] = []
            for (prev, curr) in zip(gens, gens.dropFirst()) {
                guard let prevEnd = prev.endTime else { continue }
                let gap = curr.startTime - prevEnd
                if gap >= 0 { gaps.append(gap) }
            }
            let totalGap = gaps.reduce(0, +)

            // Time-to-first-callback per gen
            let tfc = gens.compactMap { $0.timeToFirstCallbackSeconds }

            // Startup delay = session start → first recognition result
            let firstCallbackAbs = gens.compactMap { $0.firstCallbackTime }.min()
            let startupDelay = firstCallbackAbs.map { round(($0 - s.sessionStartTime) * 100) / 100 } ?? -1

            let totalChars = gens.last?.charsAtEnd ?? 0
            let generationsWithSpeech = gens.filter { $0.callbackCount > 0 }.count
            let generationsNoSpeech = gens.count - generationsWithSpeech
            let coveragePct = round((activeSeconds / duration * 100) * 10) / 10

            // Per-generation records
            let genDicts: [[String: Any]] = gens.map { g in
                var d: [String: Any] = [
                    "gen": g.gen,
                    "startTime": round(g.startTime * 1000) / 1000,
                    "charsAtStart": g.charsAtStart,
                    "charsAtEnd": g.charsAtEnd,
                    "charsDelta": g.charsDelta,
                    "callbackCount": g.callbackCount,
                    "prevLastSnippet": g.prevLastSnippet,
                    "firstSnippet": g.firstSnippet,
                    "lastSnippet": g.lastSnippet,
                    "continuityNote": continuityNote(for: g)
                ]
                if let dur = g.durationSeconds {
                    d["durationSeconds"] = round(dur * 1000) / 1000
                }
                if let code = g.errorCode { d["errorCode"] = code }
                if let end = g.endTime { d["endTime"] = round(end * 1000) / 1000 }
                if let tfc = g.timeToFirstCallbackSeconds {
                    d["timeToFirstCallbackSeconds"] = round(tfc * 1000) / 1000
                }
                return d
            }

            return [
                "summary": [
                    "totalGenerations": gens.count,
                    "completedGenerations": completed.count,
                    "generationsWithSpeech": generationsWithSpeech,
                    "generationsWithNoSpeech": generationsNoSpeech,
                    "totalCallbacks": gens.map { $0.callbackCount }.reduce(0, +),
                    "totalCharsProduced": totalChars,
                    "estimatedWords": totalChars / 5,
                    "activeRecognitionSeconds": round(activeSeconds * 10) / 10,
                    "totalGapSeconds": round(totalGap * 10) / 10,
                    "unaccountedSeconds": round(max(0, duration - activeSeconds - totalGap) * 10) / 10,
                    "coveragePercent": coveragePct,
                    "startupDelaySeconds": startupDelay
                ] as [String: Any],
                "gapAnalysis": stats(gaps),
                "timeToFirstCallback": stats(tfc),
                "generations": genDicts
            ] as [String: Any]
        }

        let dict: [String: Any] = [
            "sessionID": s.sessionID,
            "experimentMode": Self.experimentMode,
            "sessionDurationSeconds": elapsedSeconds,
            "sessionStartTime": round(s.sessionStartTime * 1000) / 1000,
            "mic": channelReport(gens: s.micGenerations),
            "participant": channelReport(gens: s.participantGenerations)
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        let dir: URL
        if let logPath {
            dir = URL(fileURLWithPath: logPath).deletingLastPathComponent()
        } else if let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dir = appSupport.appendingPathComponent("Orin/Logs")
        } else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "coverage-\(formatter.string(from: Date())).json"
        try? data.write(to: dir.appendingPathComponent(name))
    }
}
